{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Network.GRPC (RPC(..), ClientStream, ServerStream, Timeout(..), RawReply, Authority, open, RPCCall(..), singleRequest, streamReply, streamRequest, StreamDone(..)) where

import Control.Exception (Exception(..), throwIO)
import Control.Monad (forever)
import Data.Monoid ((<>))
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Binary.Builder (toLazyByteString, fromByteString, singleton, putWord32be)
import Data.Binary.Get (Decoder(..), getByteString, getInt8, getWord32be, pushChunk, pushEndOfInput, runGetIncremental)
import qualified Data.ByteString.Char8 as ByteString
import Data.ProtoLens.Encoding (encodeMessage, decodeMessage)
import Data.ProtoLens.Message (Message)

import Network.HTTP2
import Network.HPACK
import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers

class (Message (Input n), Message (Output n)) => RPC n where
  type Input n
  type Output n
  path :: n -> ByteString.ByteString

class ClientStream n where

class ServerStream n where

decodeResult :: Message a => Decoder (Either String a)
decodeResult = runGetIncremental $ do
    0 <- getInt8      -- 1byte
    n <- getWord32be  -- 4bytes
    decodeMessage <$> getByteString (fromIntegral n)

fromDecoder :: Decoder (Either String a) -> Either String a
fromDecoder (Fail _ _ msg) = Left msg
fromDecoder (Partial _)    = Left "got only a subet of the message"
fromDecoder (Done _ _ val) = val

-- | A reply.
--
-- This reply object contains a lot of information because a single gRPC call
-- returns a lot of data. A future version of the library will have a proper
-- data structure with properly named-fields on the reply object.
--
-- For now, remember:
-- - 1st item: initial HTTP2 response
-- - 2nd item: second (trailers) HTTP2 response
-- - 3rd item: proper gRPC answer
type RawReply a = Either ErrorCode (HeaderList, Maybe HeaderList, (Either String a))

data UnallowedPushPromiseReceived = UnallowedPushPromiseReceived deriving Show
instance Exception UnallowedPushPromiseReceived where

throwOnPushPromise :: PushPromiseHandler
throwOnPushPromise _ _ _ _ _ = throwIO UnallowedPushPromiseReceived

waitReply :: Message a => Http2Stream -> IncomingFlowControl -> IO (RawReply a)
waitReply stream flowControl = do
    format . fromStreamResult <$> waitStream stream flowControl throwOnPushPromise
  where
    format :: Message a => Either ErrorCode StreamResponse -> RawReply a
    format rsp = do
       (hdrs, dat, trls) <- rsp
       return (hdrs, trls, fromDecoder $ pushEndOfInput $ flip pushChunk dat $ decodeResult)

data StreamReplyDecodingError = StreamReplyDecodingError String deriving Show
instance Exception StreamReplyDecodingError where

data InvalidState = InvalidState String deriving Show
instance Exception InvalidState where

-- | The HTTP2-Authority portion of an URL (e.g., "dicioccio.fr:7777").
type Authority = ByteString.ByteString

newtype RPCCall rpc a = RPCCall {
    runRPC :: rpc
           -> Http2Client
           -> Http2Stream
           -> IncomingFlowControl
           -> OutgoingFlowControl
           -> IO a
  }

data Timeout = Timeout Int

showTimeout :: Timeout -> ByteString.ByteString
showTimeout (Timeout n) = ByteString.pack $ show n ++ "S"

-- | Call and wait (possibly forever for now) for a reply.
open :: RPC rpc
     => Http2Client
     -- ^ A connected HTTP2 client.
     -> Authority
     -- ^ The HTTP2-Authority portion of the URL (e.g., "dicioccio.fr:7777").
     -> HeaderList
     -- ^ A set of HTTP2 headers (e.g., for adding authentication headers).
     -> Timeout
     -- ^ Timeout in seconds.
     -> rpc
     -- ^ The RPC to call.
     -> RPCCall rpc a
     -- ^ The actual RPC handler.
     -> IO (Either TooMuchConcurrency a)
open conn authority extraheaders timeout rpc doStuff = do
    let icfc = _incomingFlowControl conn
    let ocfc = _outgoingFlowControl conn
    let request = [ (":method", "POST")
                  , (":scheme", "http")
                  , (":authority", authority)
                  , (":path", path rpc)
                  , ("grpc-timeout", showTimeout timeout)
                  , ("content-type", "application/grpc+proto")
                  , ("te", "trailers")
                  ] <> extraheaders
    withHttp2Stream conn $ \stream ->
        let
            initStream = headers stream request (setEndHeader)
            handler isfc osfc = do
                (runRPC doStuff) rpc conn stream isfc osfc
        in StreamDefinition initStream handler

streamReply :: (Show (Input n), Message (Input n), Message (Output n), ServerStream n)
            => Input n
            -> (HeaderList -> Either String (Output n) -> IO ())
            -> RPCCall n (HeaderList, HeaderList)
streamReply req handler = RPCCall $ \_ conn stream isfc osfc -> do
    let {
        loop decoder hdrs = _waitEvent stream >>= \case
            (StreamPushPromiseEvent _ _ _) ->
                throwIO (InvalidState "push promise")
            (StreamHeadersEvent _ trls) ->
                return (hdrs, trls)
            (StreamErrorEvent _ _) ->
                throwIO (InvalidState "stream error")
            (StreamDataEvent _ dat) -> do
                _addCredit isfc (ByteString.length dat)
                _ <- _consumeCredit isfc (ByteString.length dat)
                _ <- _updateWindow isfc
                handleAllChunks hdrs decoder dat loop
    } in do
        let ocfc = _outgoingFlowControl conn
        sendSingleMessage req setEndStream conn ocfc stream osfc
        _waitEvent stream >>= \case
            StreamHeadersEvent _ hdrs ->
                loop decodeResult hdrs
            _                         ->
                throwIO (InvalidState "no headers")
  where
    handleAllChunks hdrs decoder dat exitLoop =
       case pushChunk decoder dat of
           (Done unusedDat _ val) -> do
               handler hdrs val
               handleAllChunks hdrs decodeResult unusedDat exitLoop
           failure@(Fail _ _ err)   -> do
               handler hdrs (fromDecoder failure)
               throwIO (StreamReplyDecodingError err)
           partial@(Partial _)    ->
               exitLoop partial hdrs

data StreamDone = StreamDone

streamRequest :: (Message (Input n), Message (Output n), ClientStream n)
              => (IO (Either StreamDone (Input n)))
              -> RPCCall n (RawReply (Output n))
streamRequest handler = RPCCall $ \_ conn stream isfc streamFlowControl ->
    let ocfc = _outgoingFlowControl conn
        go = do
            nextEvent <- handler
            case nextEvent of
                Right msg -> do
                    sendSingleMessage msg id conn ocfc stream streamFlowControl
                    go
                Left _ -> do
                    sendData conn stream setEndStream ""
                    waitReply stream isfc
    in go

sendSingleMessage :: Message a
                  => a
                  -> FlagSetter
                  -> Http2Client
                  -> OutgoingFlowControl
                  -> Http2Stream
                  -> OutgoingFlowControl
                  -> IO ()
sendSingleMessage msg flagMod conn connectionFlowControl stream streamFlowControl = do
    let goUpload dat = do
            let !wanted = ByteString.length dat
            gotStream <- _withdrawCredit streamFlowControl wanted
            got       <- _withdrawCredit connectionFlowControl gotStream
            _receiveCredit streamFlowControl (gotStream - got)
            if got == wanted
            then
                sendData conn stream flagMod dat
            else do
                sendData conn stream id (ByteString.take got dat)
                goUpload (ByteString.drop got dat)
    goUpload . toStrict . toLazyByteString . encodePlainMessage $ msg
  where
    encodePlainMessage plain =
        let bin = encodeMessage plain
        in singleton 0 <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString bin

singleRequest :: (Message (Input n), Message (Output n))
              => Input n
              -> RPCCall n (RawReply (Output n))
singleRequest msg = RPCCall $ \_ conn stream isfc osfc -> do
    let ocfc = _outgoingFlowControl conn
    sendSingleMessage msg setEndStream conn ocfc stream osfc
    waitReply stream isfc
