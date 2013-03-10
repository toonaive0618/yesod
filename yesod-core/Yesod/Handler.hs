{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE DeriveDataTypeable #-}
---------------------------------------------------------
--
-- Module        : Yesod.Handler
-- Copyright     : Michael Snoyman
-- License       : BSD3
--
-- Maintainer    : Michael Snoyman <michael@snoyman.com>
-- Stability     : stable
-- Portability   : portable
--
-- Define Handler stuff.
--
---------------------------------------------------------
module Yesod.Handler
    ( -- * Type families
      YesodSubRoute (..)
      -- * Handler monad
    , GHandler
      -- ** Read information from handler
    , getYesod
    , getYesodSub
    , getUrlRender
    , getUrlRenderParams
    , getCurrentRoute
    , getRouteToMaster
    , getRequest
    , waiRequest
    , runRequestBody
      -- * Special responses
      -- ** Redirecting
    , RedirectUrl (..)
    , redirect
    , redirectWith
    , redirectToPost
      -- ** Errors
    , notFound
    , badMethod
    , permissionDenied
    , permissionDeniedI
    , invalidArgs
    , invalidArgsI
      -- ** Short-circuit responses.
    , sendFile
    , sendFilePart
    , sendResponse
    , sendResponseStatus
    , sendResponseCreated
    , sendWaiResponse
      -- * Setting headers
    , setCookie
    , getExpires
    , deleteCookie
    , setHeader
    , setLanguage
      -- ** Content caching and expiration
    , cacheSeconds
    , neverExpires
    , alreadyExpired
    , expiresAt
      -- * Session
    , SessionMap
    , lookupSession
    , lookupSessionBS
    , getSession
    , setSession
    , setSessionBS
    , deleteSession
    , clearSession
      -- ** Ultimate destination
    , setUltDest
    , setUltDestCurrent
    , setUltDestReferer
    , redirectUltDest
    , clearUltDest
      -- ** Messages
    , setMessage
    , setMessageI
    , getMessage
      -- * Helpers for specific content
      -- ** Hamlet
    , hamletToContent
    , hamletToRepHtml
      -- ** Misc
    , newIdent
      -- * Lifting
    , MonadLift (..)
    , handlerToIO
      -- * i18n
    , getMessageRender
      -- * Per-request caching
    , CacheKey
    , mkCacheKey
    , cacheLookup
    , cacheInsert
    , cacheDelete
      -- * Internal Yesod
    , YesodApp
    , runSubsiteGetter
    , HandlerData
    , ErrorResponse (..)
    ) where

import Prelude hiding (catch)
import Yesod.Internal.Request
import Yesod.Internal
import Data.Time (UTCTime, getCurrentTime, addUTCTime)

import Control.Exception hiding (Handler, catch, finally)
import Control.Applicative

import Control.Monad (liftM)

import Control.Monad.IO.Class

import qualified Network.Wai as W
import qualified Network.HTTP.Types as H

import Text.Hamlet
import qualified Text.Blaze.Html.Renderer.Text as RenderText
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.Text.Lazy as TL

import qualified Data.Map as Map
import qualified Data.ByteString as S

import Yesod.Content
import Data.Maybe (mapMaybe)
import Web.Cookie (SetCookie (..))
import Control.Arrow ((***))
import qualified Network.Wai.Parse as NWP
import Data.Monoid (mappend, mempty, Endo (..))
import qualified Data.ByteString.Char8 as S8
import Data.Text (Text)
import Text.Shakespeare.I18N (RenderMessage (..))

import Text.Blaze.Html (toHtml, preEscapedToMarkup)
#define preEscapedText preEscapedToMarkup

import qualified Yesod.Internal.Cache as Cache
import Yesod.Internal.Cache (mkCacheKey)
import qualified Data.IORef as I
import Control.Monad.Trans.Resource (ResourceT, runResourceT)
import Yesod.Routes.Class (Route)
import Yesod.Core.Types
import Yesod.Core.Trans.Class

class YesodSubRoute s y where
    fromSubRoute :: s -> y -> Route s -> Route y

get :: GHandler sub master GHState
get = do
    hd <- ask
    liftIO $ I.readIORef $ handlerState hd

put :: GHState -> GHandler sub master ()
put g = do
    hd <- ask
    liftIO $ I.writeIORef (handlerState hd) g

modify :: (GHState -> GHState) -> GHandler sub master ()
modify f = do
    hd <- ask
    liftIO $ I.atomicModifyIORef (handlerState hd) $ \g -> (f g, ())

tell :: Endo [Header] -> GHandler sub master ()
tell hs = modify $ \g -> g { ghsHeaders = ghsHeaders g `mappend` hs }

class SubsiteGetter g m s | g -> s where
  runSubsiteGetter :: g -> m s

instance (master ~ master'
         ) => SubsiteGetter (master -> sub) (GHandler anySub master') sub where
  runSubsiteGetter getter = getter <$> getYesod

instance (anySub ~ anySub'
         ,master ~ master'
         ) => SubsiteGetter (GHandler anySub master sub) (GHandler anySub' master') sub where
  runSubsiteGetter = id

getRequest :: GHandler s m YesodRequest
getRequest = handlerRequest `liftM` ask

hcError :: ErrorResponse -> GHandler sub master a
hcError = liftIO . throwIO . HCError

runRequestBody :: GHandler s m RequestBodyContents
runRequestBody = do
    hd <- ask
    let getUpload = rheUpload $ handlerEnv hd
        len = W.requestBodyLength
            $ reqWaiRequest
            $ handlerRequest hd
        upload = getUpload len
    x <- get
    case ghsRBC x of
        Just rbc -> return rbc
        Nothing -> do
            rr <- waiRequest
            rbc <- lift $ rbHelper upload rr
            put x { ghsRBC = Just rbc }
            return rbc

rbHelper :: FileUpload -> W.Request -> ResourceT IO RequestBodyContents
rbHelper upload =
    case upload of
        FileUploadMemory s -> rbHelper' s mkFileInfoLBS
        FileUploadDisk s -> rbHelper' s mkFileInfoFile
        FileUploadSource s -> rbHelper' s mkFileInfoSource

rbHelper' :: NWP.BackEnd x
          -> (Text -> Text -> x -> FileInfo)
          -> W.Request
          -> ResourceT IO ([(Text, Text)], [(Text, FileInfo)])
rbHelper' backend mkFI req =
    (map fix1 *** mapMaybe fix2) <$> (NWP.parseRequestBody backend req)
  where
    fix1 = go *** go
    fix2 (x, NWP.FileInfo a' b c)
        | S.null a = Nothing
        | otherwise = Just (go x, mkFI (go a) (go b) c)
      where
        a
            | S.length a' < 2 = a'
            | S8.head a' == '"' && S8.last a' == '"' = S.tail $ S.init a'
            | S8.head a' == '\'' && S8.last a' == '\'' = S.tail $ S.init a'
            | otherwise = a'
    go = decodeUtf8With lenientDecode

-- | Get the sub application argument.
getYesodSub :: GHandler sub master sub
getYesodSub = (rheSub . handlerEnv) `liftM` ask

-- | Get the master site appliation argument.
getYesod :: GHandler sub master master
getYesod = (rheMaster . handlerEnv) `liftM` ask

-- | Get the URL rendering function.
getUrlRender :: GHandler sub master (Route master -> Text)
getUrlRender = do
    x <- (rheRender . handlerEnv) `liftM` ask
    return $ flip x []

-- | The URL rendering function with query-string parameters.
getUrlRenderParams
    :: GHandler sub master (Route master -> [(Text, Text)] -> Text)
getUrlRenderParams = (rheRender . handlerEnv) `liftM` ask

-- | Get the route requested by the user. If this is a 404 response- where the
-- user requested an invalid route- this function will return 'Nothing'.
getCurrentRoute :: GHandler sub master (Maybe (Route sub))
getCurrentRoute = (rheRoute . handlerEnv) `liftM` ask

-- | Get the function to promote a route for a subsite to a route for the
-- master site.
getRouteToMaster :: GHandler sub master (Route sub -> Route master)
getRouteToMaster = (rheToMaster . handlerEnv) `liftM` ask


-- | Returns a function that runs 'GHandler' actions inside @IO@.
--
-- Sometimes you want to run an inner 'GHandler' action outside
-- the control flow of an HTTP request (on the outer 'GHandler'
-- action).  For example, you may want to spawn a new thread:
--
-- @
-- getFooR :: Handler RepHtml
-- getFooR = do
--   runInnerHandler <- handlerToIO
--   liftIO $ forkIO $ runInnerHandler $ do
--     /Code here runs inside GHandler but on a new thread./
--     /This is the inner GHandler./
--     ...
--   /Code here runs inside the request's control flow./
--   /This is the outer GHandler./
--   ...
-- @
--
-- Another use case for this function is creating a stream of
-- server-sent events using 'GHandler' actions (see
-- @yesod-eventsource@).
--
-- Most of the environment from the outer 'GHandler' is preserved
-- on the inner 'GHandler', however:
--
--  * The request body is cleared (otherwise it would be very
--  difficult to prevent huge memory leaks).
--
--  * The cache is cleared (see 'CacheKey').
--
-- Changes to the response made inside the inner 'GHandler' are
-- ignored (e.g., session variables, cookies, response headers).
-- This allows the inner 'GHandler' to outlive the outer
-- 'GHandler' (e.g., on the @forkIO@ example above, a response
-- may be sent to the client without killing the new thread).
handlerToIO :: MonadIO m => GHandler sub master (GHandler sub master a -> m a)
handlerToIO =
  GHandler $ \oldHandlerData -> do
    -- Let go of the request body, cache and response headers.
    let oldReq    = handlerRequest oldHandlerData
        oldWaiReq = reqWaiRequest oldReq
        newWaiReq = oldWaiReq { W.requestBody = mempty
                              , W.requestBodyLength = W.KnownLength 0
                              }
        newReq    = oldReq { reqWaiRequest = newWaiReq }
        clearedOldHandlerData =
          oldHandlerData { handlerRequest = err "handlerRequest never here"
                         , handlerState   = err "handlerState never here" }
            where
              err :: String -> a
              err = error . ("handlerToIO: clearedOldHandlerData/" ++)
    newState <- liftIO $ do
      oldState <- I.readIORef (handlerState oldHandlerData)
      return $ oldState { ghsRBC = Nothing
                        , ghsIdent = 1
                        , ghsCache = mempty
                        , ghsHeaders = mempty }

    -- Return GHandler running function.
    return $ \(GHandler f) -> liftIO $ do
      -- The state IORef needs to be created here, otherwise it
      -- will be shared by different invocations of this function.
      newStateIORef <- I.newIORef newState
      runResourceT $ f clearedOldHandlerData
                         { handlerRequest = newReq
                         , handlerState   = newStateIORef }


-- | Redirect to the given route.
-- HTTP status code 303 for HTTP 1.1 clients and 302 for HTTP 1.0
-- This is the appropriate choice for a get-following-post
-- technique, which should be the usual use case.
--
-- If you want direct control of the final status code, or need a different
-- status code, please use 'redirectWith'.
redirect :: RedirectUrl master url => url -> GHandler sub master a
redirect url = do
    req <- waiRequest
    let status =
            if W.httpVersion req == H.http11
                then H.status303
                else H.status302
    redirectWith status url

-- | Redirect to the given URL with the specified status code.
redirectWith :: RedirectUrl master url => H.Status -> url -> GHandler sub master a
redirectWith status url = do
    urlText <- toTextUrl url
    liftIO $ throwIO $ HCRedirect status urlText

ultDestKey :: Text
ultDestKey = "_ULT"

-- | Sets the ultimate destination variable to the given route.
--
-- An ultimate destination is stored in the user session and can be loaded
-- later by 'redirectUltDest'.
setUltDest :: RedirectUrl master url => url -> GHandler sub master ()
setUltDest url = do
    urlText <- toTextUrl url
    setSession ultDestKey urlText

-- | Same as 'setUltDest', but uses the current page.
--
-- If this is a 404 handler, there is no current page, and then this call does
-- nothing.
setUltDestCurrent :: GHandler sub master ()
setUltDestCurrent = do
    route <- getCurrentRoute
    case route of
        Nothing -> return ()
        Just r -> do
            tm <- getRouteToMaster
            gets' <- reqGetParams `liftM` handlerRequest `liftM` ask
            setUltDest (tm r, gets')

-- | Sets the ultimate destination to the referer request header, if present.
--
-- This function will not overwrite an existing ultdest.
setUltDestReferer :: GHandler sub master ()
setUltDestReferer = do
    mdest <- lookupSession ultDestKey
    maybe
        (waiRequest >>= maybe (return ()) setUltDestBS . lookup "referer" . W.requestHeaders)
        (const $ return ())
        mdest
  where
    setUltDestBS = setUltDest . T.pack . S8.unpack

-- | Redirect to the ultimate destination in the user's session. Clear the
-- value from the session.
--
-- The ultimate destination is set with 'setUltDest'.
--
-- This function uses 'redirect', and thus will perform a temporary redirect to
-- a GET request.
redirectUltDest :: RedirectUrl master url
                => url -- ^ default destination if nothing in session
                -> GHandler sub master a
redirectUltDest def = do
    mdest <- lookupSession ultDestKey
    deleteSession ultDestKey
    maybe (redirect def) redirect mdest

-- | Remove a previously set ultimate destination. See 'setUltDest'.
clearUltDest :: GHandler sub master ()
clearUltDest = deleteSession ultDestKey

msgKey :: Text
msgKey = "_MSG"

-- | Sets a message in the user's session.
--
-- See 'getMessage'.
setMessage :: Html -> GHandler sub master ()
setMessage = setSession msgKey . T.concat . TL.toChunks . RenderText.renderHtml

-- | Sets a message in the user's session.
--
-- See 'getMessage'.
setMessageI :: (RenderMessage y msg) => msg -> GHandler sub y ()
setMessageI msg = do
    mr <- getMessageRender
    setMessage $ toHtml $ mr msg

-- | Gets the message in the user's session, if available, and then clears the
-- variable.
--
-- See 'setMessage'.
getMessage :: GHandler sub master (Maybe Html)
getMessage = do
    mmsg <- liftM (fmap preEscapedText) $ lookupSession msgKey
    deleteSession msgKey
    return mmsg

-- | Bypass remaining handler code and output the given file.
--
-- For some backends, this is more efficient than reading in the file to
-- memory, since they can optimize file sending via a system call to sendfile.
sendFile :: ContentType -> FilePath -> GHandler sub master a
sendFile ct fp = liftIO . throwIO $ HCSendFile ct fp Nothing

-- | Same as 'sendFile', but only sends part of a file.
sendFilePart :: ContentType
             -> FilePath
             -> Integer -- ^ offset
             -> Integer -- ^ count
             -> GHandler sub master a
sendFilePart ct fp off count =
    liftIO . throwIO $ HCSendFile ct fp $ Just $ W.FilePart off count

-- | Bypass remaining handler code and output the given content with a 200
-- status code.
sendResponse :: HasReps c => c -> GHandler sub master a
sendResponse = liftIO . throwIO . HCContent H.status200
             . chooseRep

-- | Bypass remaining handler code and output the given content with the given
-- status code.
sendResponseStatus :: HasReps c => H.Status -> c -> GHandler s m a
sendResponseStatus s = liftIO . throwIO . HCContent s
                     . chooseRep

-- | Send a 201 "Created" response with the given route as the Location
-- response header.
sendResponseCreated :: Route m -> GHandler s m a
sendResponseCreated url = do
    r <- getUrlRender
    liftIO . throwIO $ HCCreated $ r url

-- | Send a 'W.Response'. Please note: this function is rarely
-- necessary, and will /disregard/ any changes to response headers and session
-- that you have already specified. This function short-circuits. It should be
-- considered only for very specific needs. If you are not sure if you need it,
-- you don't.
sendWaiResponse :: W.Response -> GHandler s m b
sendWaiResponse = liftIO . throwIO . HCWai

-- | Return a 404 not found page. Also denotes no handler available.
notFound :: GHandler sub master a
notFound = hcError NotFound

-- | Return a 405 method not supported page.
badMethod :: GHandler sub master a
badMethod = do
    w <- waiRequest
    hcError $ BadMethod $ W.requestMethod w

-- | Return a 403 permission denied page.
permissionDenied :: Text -> GHandler sub master a
permissionDenied = hcError . PermissionDenied

-- | Return a 403 permission denied page.
permissionDeniedI :: RenderMessage master msg => msg -> GHandler sub master a
permissionDeniedI msg = do
    mr <- getMessageRender
    permissionDenied $ mr msg

-- | Return a 400 invalid arguments page.
invalidArgs :: [Text] -> GHandler sub master a
invalidArgs = hcError . InvalidArgs

-- | Return a 400 invalid arguments page.
invalidArgsI :: RenderMessage y msg => [msg] -> GHandler s y a
invalidArgsI msg = do
    mr <- getMessageRender
    invalidArgs $ map mr msg

------- Headers
-- | Set the cookie on the client.

setCookie :: SetCookie
          -> GHandler sub master ()
setCookie = addHeader . AddCookie

-- | Helper function for setCookieExpires value
getExpires :: Int -- ^ minutes
          -> IO UTCTime
getExpires m = do
    now <- liftIO getCurrentTime
    return $ fromIntegral (m * 60) `addUTCTime` now


-- | Unset the cookie on the client.
--
-- Note: although the value used for key and path is 'Text', you should only
-- use ASCII values to be HTTP compliant.
deleteCookie :: Text -- ^ key
             -> Text -- ^ path
             -> GHandler sub master ()
deleteCookie a = addHeader . DeleteCookie (encodeUtf8 a) . encodeUtf8


-- | Set the language in the user session. Will show up in 'languages' on the
-- next request.
setLanguage :: Text -> GHandler sub master ()
setLanguage = setSession langKey

-- | Set an arbitrary response header.
--
-- Note that, while the data type used here is 'Text', you must provide only
-- ASCII value to be HTTP compliant.
setHeader :: Text -> Text -> GHandler sub master ()
setHeader a = addHeader . Header (encodeUtf8 a) . encodeUtf8

-- | Set the Cache-Control header to indicate this response should be cached
-- for the given number of seconds.
cacheSeconds :: Int -> GHandler s m ()
cacheSeconds i = setHeader "Cache-Control" $ T.concat
    [ "max-age="
    , T.pack $ show i
    , ", public"
    ]

-- | Set the Expires header to some date in 2037. In other words, this content
-- is never (realistically) expired.
neverExpires :: GHandler s m ()
neverExpires = setHeader "Expires" "Thu, 31 Dec 2037 23:55:55 GMT"

-- | Set an Expires header in the past, meaning this content should not be
-- cached.
alreadyExpired :: GHandler s m ()
alreadyExpired = setHeader "Expires" "Thu, 01 Jan 1970 05:05:05 GMT"

-- | Set an Expires header to the given date.
expiresAt :: UTCTime -> GHandler s m ()
expiresAt = setHeader "Expires" . formatRFC1123

-- | Set a variable in the user's session.
--
-- The session is handled by the clientsession package: it sets an encrypted
-- and hashed cookie on the client. This ensures that all data is secure and
-- not tampered with.
setSession :: Text -- ^ key
           -> Text -- ^ value
           -> GHandler sub master ()
setSession k = setSessionBS k . encodeUtf8

-- | Same as 'setSession', but uses binary data for the value.
setSessionBS :: Text
             -> S.ByteString
             -> GHandler sub master ()
setSessionBS k = modify . modSession . Map.insert k

-- | Unsets a session variable. See 'setSession'.
deleteSession :: Text -> GHandler sub master ()
deleteSession = modify . modSession . Map.delete

-- | Clear all session variables.
--
-- Since: 1.0.1
clearSession :: GHandler sub master ()
clearSession = modify $ \x -> x { ghsSession = Map.empty }

modSession :: (SessionMap -> SessionMap) -> GHState -> GHState
modSession f x = x { ghsSession = f $ ghsSession x }

-- | Internal use only, not to be confused with 'setHeader'.
addHeader :: Header -> GHandler sub master ()
addHeader = tell . Endo . (:)

-- | Some value which can be turned into a URL for redirects.
class RedirectUrl master a where
    -- | Converts the value to the URL and a list of query-string parameters.
    toTextUrl :: a -> GHandler sub master Text

instance RedirectUrl master Text where
    toTextUrl = return

instance RedirectUrl master String where
    toTextUrl = toTextUrl . T.pack

instance RedirectUrl master (Route master) where
    toTextUrl url = do
        r <- getUrlRender
        return $ r url

instance (key ~ Text, val ~ Text) => RedirectUrl master (Route master, [(key, val)]) where
    toTextUrl (url, params) = do
        r <- getUrlRenderParams
        return $ r url params

instance (key ~ Text, val ~ Text) => RedirectUrl master (Route master, Map.Map key val) where
    toTextUrl (url, params) = toTextUrl (url, Map.toList params)

-- | Lookup for session data.
lookupSession :: Text -> GHandler s m (Maybe Text)
lookupSession = (fmap . fmap) (decodeUtf8With lenientDecode) . lookupSessionBS

-- | Lookup for session data in binary format.
lookupSessionBS :: Text -> GHandler s m (Maybe S.ByteString)
lookupSessionBS n = do
    m <- liftM ghsSession get
    return $ Map.lookup n m

-- | Get all session variables.
getSession :: GHandler sub master SessionMap
getSession = liftM ghsSession get

-- | Get a unique identifier.
newIdent :: GHandler sub master Text
newIdent = do
    x <- get
    let i' = ghsIdent x + 1
    put x { ghsIdent = i' }
    return $ T.pack $ 'h' : show i'

-- | Redirect to a POST resource.
--
-- This is not technically a redirect; instead, it returns an HTML page with a
-- POST form, and some Javascript to automatically submit the form. This can be
-- useful when you need to post a plain link somewhere that needs to cause
-- changes on the server.
redirectToPost :: RedirectUrl master url => url -> GHandler sub master a
redirectToPost url = do
    urlText <- toTextUrl url
    hamletToRepHtml [hamlet|
$newline never
$doctype 5

<html>
    <head>
        <title>Redirecting...
    <body onload="document.getElementById('form').submit()">
        <form id="form" method="post" action=#{urlText}>
            <noscript>
                <p>Javascript has been disabled; please click on the button below to be redirected.
            <input type="submit" value="Continue">
|] >>= sendResponse

-- | Converts the given Hamlet template into 'Content', which can be used in a
-- Yesod 'Response'.
hamletToContent :: HtmlUrl (Route master) -> GHandler sub master Content
hamletToContent h = do
    render <- getUrlRenderParams
    return $ toContent $ h render

-- | Wraps the 'Content' generated by 'hamletToContent' in a 'RepHtml'.
hamletToRepHtml :: HtmlUrl (Route master) -> GHandler sub master RepHtml
hamletToRepHtml = liftM RepHtml . hamletToContent

-- | Get the request\'s 'W.Request' value.
waiRequest :: GHandler sub master W.Request
waiRequest = reqWaiRequest `liftM` getRequest

getMessageRender :: RenderMessage master message => GHandler s master (message -> Text)
getMessageRender = do
    m <- getYesod
    l <- reqLangs `liftM` getRequest
    return $ renderMessage m l

cacheLookup :: CacheKey a -> GHandler sub master (Maybe a)
cacheLookup k = do
    gs <- get
    return $ Cache.lookup k $ ghsCache gs

cacheInsert :: CacheKey a -> a -> GHandler sub master ()
cacheInsert k v = modify $ \gs ->
    gs { ghsCache = Cache.insert k v $ ghsCache gs }

cacheDelete :: CacheKey a -> GHandler sub master ()
cacheDelete k = modify $ \gs ->
    gs { ghsCache = Cache.delete k $ ghsCache gs }

ask :: GHandler sub master (HandlerData sub master)
ask = GHandler return
