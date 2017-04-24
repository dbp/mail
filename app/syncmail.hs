#!/usr/bin/env stack
-- stack --resolver lts-7.9 --install-ghc runghc --package imap-0.3.0.0 --package rolling-queue-0.1 --package monadIO-0.10.1.4 --package shelly --package logging --package aeson --package ekg
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
module Main where

import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import Data.Maybe
import Data.Aeson
import Data.Aeson.Types
import Control.Logging
import Shelly
import qualified Data.Text.IO as T
import qualified Data.Text as T
import Control.Monad
import Network.Connection
import Network.IMAP
import Network.IMAP.Types
import qualified Data.STM.RollingQueue as RQ
import Control.Concurrent.STM.TBQueue
import Data.Monoid
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.UUID.V4 as UUID
import qualified Data.UUID as UUID
default (T.Text)

data Request = Noop | CheckFiles | SyncInbox | SyncAll deriving Show

instance Monoid Request where
  mempty = Noop
  mappend Noop r = r
  mappend r Noop = r
  mappend SyncAll _ = SyncAll
  mappend _ SyncAll = SyncAll
  mappend _ SyncInbox = SyncInbox
  mappend SyncInbox _ = SyncInbox
  mappend CheckFiles CheckFiles = CheckFiles

readAll :: TBQueue a -> IO [a]
readAll q = atomically $ readAll' True
  where readAll' isFirst = do val <- if isFirst then Just <$> readTBQueue q else tryReadTBQueue q
                              case val of
                                Nothing -> return []
                                Just v -> (v :) <$> readAll' False

imapThread :: TBQueue Request -> TVar IMAPConnection -> IO ()
imapThread chan cvar = do
  conn <- readTVarIO cvar
  msg <- atomically . RQ.read . untaggedQueue $ conn
  case msg of
    (Exists _, _) -> atomically $ writeTBQueue chan SyncInbox
    r -> do print r
            return ()
  log' "Imap ack."
  imapThread chan cvar

oneMinute = 60000000

connect :: IO IMAPConnection
connect = do let tls = TLSSettingsSimple False False False
             let params = ConnectionParams "imap.fastmail.com" 993 (Just tls) Nothing
             conn <- connectServer params Nothing
             pass <- last . T.words . head . T.lines <$> T.readFile "/Users/dbp/.authinfo"
             r <- simpleFormat $ login conn "dbp@dbpmail.net" pass
             log' $ "Logging in... " <> case r of
                                          Right _ -> ""
                                          Left err -> T.pack (show err)
             simpleFormat $ select conn "INBOX"
             simpleFormat $ sendCommand conn "IDLE"
             return conn

keepAliveThread :: TVar IMAPConnection -> IO ()
keepAliveThread cvar = do conn <- readTVarIO cvar
                          status <- readTVarIO (connectionState conn)
                          let reconnect = do
                               log' "Reconnecting to server..."
                               newconn <- connect
                               atomically $ writeTVar cvar newconn
                               close conn
                               return ()
                          case status of
                            Disconnected -> reconnect
                            UndefinedState -> reconnect
                            Connected -> return ()
                          threadDelay (13 * oneMinute)
                          sendCommand conn "DONE"
                          sendCommand conn "IDLE"
                          log' "Keepalive ack."
                          keepAliveThread cvar

updateNotMuch :: Sh ()
updateNotMuch = do run_ "notmuch" ["new", "--quiet"]
                   run_ "notmuch" ["tag", "-inbox",
                                   "folder:sent", "and", "tag:inbox"]
                   run_ "notmuch" ["tag", "+sent",
                                   "folder:sent", "and", "not", "tag:sent"]
                   run_ "notmuch" ["tag", "-inbox",
                                   "tag:inbox", "and", "not", "folder:inbox"]

getNewName :: T.Text -> T.Text -> Sh T.Text
getNewName curname dir = do uuid <- liftIO UUID.nextRandom
                            let flags = last $ T.splitOn ":" curname
                            return $ dir <> UUID.toText uuid <> ":" <> flags


moveMail :: Sh Request
moveMail = do files <- T.lines <$> run "notmuch" ["search",
                                                  "--output=files",
                                                  "folder:inbox", "and",
                                                  "not", "tag:inbox"]
              r1 <- case files of
                      [] -> return Noop
                      _ -> do mapM_ (\f -> do
                                        target <- getNewName f "/Users/dbp/mail/archive/cur/"
                                        mv (fromText f) (fromText target))
                                files 
                              run_ "notmuch" ["new", "--quiet"]
                              return SyncAll
              files <- T.lines <$> run "notmuch" ["search",
                                                  "--output=files",
                                                  "not", "folder:inbox",
                                                  "and", "tag:inbox"] 
              r2 <- case files of
                      [] -> return Noop
                      _ -> do mapM_ (\f -> do
                                        target <- getNewName f "/Users/dbp/mail/inbox/cur/"
                                        mv (fromText f) (fromText target))
                                files
                              run_ "notmuch" ["new", "--quiet"]
                              return SyncAll
              return (r1 <> r2)

data Summary = Summary T.Text T.Text deriving Show
instance FromJSON Summary where
  parseJSON = withObject "Summary" $ \v -> Summary
        <$> v .: "authors"
        <*> v .: "subject"

getSummary j = decode (TL.encodeUtf8 . TL.fromStrict $ j)

notifyNewMail :: Sh ()
notifyNewMail = do
  msgs' <- decode . TL.encodeUtf8 . TL.fromStrict <$>
    run "notmuch" ["search", "--format=json",
                    "tag:inbox", "and",
                    "tag:unprocessed"]
  let msgs = fromMaybe [] msgs' :: [Summary]
  when (not $ null msgs) $ liftIO (log' "Notifying of new messages...")
  mapM_ (\(Summary auth sub) ->
           asyncSh $ run_ "terminal-notifier" ["-message",sub,"-title",auth,"-sender", "org.gnu.Emacs", "-activate", "org.gnu.Emacs", "-actions","''", "-timeout", "60"])
    msgs
  run_ "notmuch" ["tag", "-unprocessed", "tag:unprocessed"]

syncThread :: TBQueue Request -> IO ()
syncThread chan = do req <- mconcat <$> readAll chan
                     case req of
                       CheckFiles -> do
                         log' "Checking for local database updates..."
                         r <- shelly $ silently $ moveMail
                         atomically $ writeTBQueue chan r
                       SyncInbox -> do
                         log' "Received push notification..."
                         r <- shelly $ silently $ do
                           run_ "mbsync" ["-q", "dbpmail-inbox"]
                           updateNotMuch
                           notifyNewMail
                           moveMail
                         atomically $ writeTBQueue chan r
                       SyncAll -> do
                         log' "Synchronizing all messages..."
                         r <- shelly $ silently $ do
                           run_ "mbsync" ["-qa"]
                           updateNotMuch
                           notifyNewMail
                           moveMail
                         atomically $ writeTBQueue chan r
                       Noop -> return ()
                     threadDelay (oneMinute `div` 5)
                     -- If requests came in while we were
                     -- syncing, we want to handle them,
                     -- but wait a little while so we
                     -- don't hammer the server.
                     log' "Sync ack."
                     syncThread chan

periodicThread :: TBQueue Request -> IO ()
periodicThread chan = do atomically $ writeTBQueue chan SyncAll
                         threadDelay (10 * oneMinute)
                         log' "Periodic ack."
                         periodicThread chan

filesThread :: TBQueue Request -> IO ()
filesThread chan = do atomically $ writeTBQueue chan CheckFiles
                      threadDelay oneMinute
                      log' "Files ack."
                      filesThread chan

main :: IO ()
main = withStdoutLogging $ do
  -- forkServer "localhost" 8000
  conn <- connect
  cvar <- newTVarIO conn
  chan <- atomically $ newTBQueue 10
  forkIO $ imapThread chan cvar
  forkIO $ keepAliveThread cvar
  forkIO $ syncThread chan
  forkIO $ filesThread chan
  forever $ periodicThread chan 


-- Local Variables:
-- mode: haskell
-- End:
