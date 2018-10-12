#!/usr/bin/env stack
-- stack --resolver lts-7.9 --install-ghc runghc --package imap-0.3.0.0 --package rolling-queue-0.1 --package monadIO-0.10.1.4 --package shelly --package logging --package aeson --package ekg
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
module Main where

import           Capataz                        (Capataz, WorkerId, WorkerRestartStrategy (Permanent),
                                                 buildWorkerOptions,
                                                 forkCapataz, forkWorker,
                                                 joinCapatazThread,
                                                 onSystemEventL, set,
                                                 terminateCapataz_,
                                                 terminateProcess,
                                                 workerRestartStrategyL)
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TBQueue
import           Control.Exception              (SomeException, catch, finally)
import           Control.Logging
import           Control.Monad
import           Data.Aeson
import           Data.Aeson.Types
import           Data.Maybe
import           Data.Monoid
import           Data.Semigroup
import qualified Data.STM.RollingQueue          as RQ
import qualified Data.Text                      as T
import qualified Data.Text.IO                   as T
import qualified Data.Text.Lazy                 as TL
import qualified Data.Text.Lazy.Encoding        as TL
import           Data.Time.Clock
import qualified Data.UUID                      as UUID
import qualified Data.UUID.V4                   as UUID
import           Network.Connection
import           Network.IMAP
import           Network.IMAP.Types
import           RIO                            (display, utf8BuilderToText)
import           Shelly

default (T.Text)


home :: T.Text
home = "/Users/dbp"

data Request = Noop | CheckFiles | SyncInbox | SyncAll deriving Show

instance Monoid Request where
  mempty = Noop
  mappend Noop r                = r
  mappend r Noop                = r
  mappend SyncAll _             = SyncAll
  mappend _ SyncAll             = SyncAll
  mappend _ SyncInbox           = SyncInbox
  mappend SyncInbox _           = SyncInbox
  mappend CheckFiles CheckFiles = CheckFiles

instance Semigroup Request where
  (<>) = mappend

readAll :: TBQueue a -> IO [a]
readAll q = atomically $ readAll' True
  where readAll' isFirst = do val <- if isFirst then Just <$> readTBQueue q else tryReadTBQueue q
                              case val of
                                Nothing -> return []
                                Just v  -> (v :) <$> readAll' False

imapThread :: TBQueue Request -> TVar IMAPConnection -> IO ()
imapThread chan cvar = do
  conn' <- readTVarIO cvar
  status <- readTVarIO (connectionState conn')
  conn <- case status of
            Connected -> return conn'
            _ -> do newconn <- connect
                    atomically $ writeTVar cvar newconn
                    close conn'
                    return newconn
  msg <- atomically . RQ.read . untaggedQueue $ conn
  case msg of
    (Exists _, _) -> atomically $ writeTBQueue chan SyncInbox
    r             -> return ()
  log' "Imap ack."
  imapThread chan cvar

oneMinute = 60000000

connect :: IO IMAPConnection
connect = do let tls = TLSSettingsSimple False False False
             let params = ConnectionParams "imap.fastmail.com" 993 (Just tls) Nothing
             conn <- connectServer params Nothing
             pass <- last . T.words . head . T.lines <$> T.readFile (T.unpack $ home <> "/.authinfo")
             r <- simpleFormat $ login conn "dbp@dbpmail.net" pass
             log' $ "Logging in... " <> case r of
                                          Right _  -> ""
                                          Left err -> T.pack (show err)
             simpleFormat $ select conn "INBOX"
             simpleFormat $ sendCommand conn "IDLE"
             return conn

retryTenSeconds :: IO a -> IO a
retryTenSeconds f = catch f $ \(e::SomeException) -> do
  log' $ "Exception raised: " <> T.pack (show e) <> ", sleeping and retrying."
  threadDelay (oneMinute `div` 6)
  retryTenSeconds f

reconnectThread :: Capataz IO -> WorkerId -> TVar UTCTime -> TVar IMAPConnection -> IO ()
reconnectThread super imapid lastchecked cvar =
  do conn <- readTVarIO cvar
     status <- readTVarIO (connectionState conn)
     log' "Reconnect ack."
     let reconnect = do
          log' "Reconnecting to server..."
          terminateProcess "Need to reconnect" imapid super
          return ()
     case status of
       Disconnected -> reconnect
       UndefinedState -> reconnect
       Connected -> do last <- readTVarIO lastchecked
                       now <- getCurrentTime
                       atomically $ writeTVar lastchecked now
                       log' $ "Checked " <> (T.pack (show (diffUTCTime now last))) <> " ago."
                       -- NOTE(dbp 2017-05-22): Conversion to NominalDiffTime is
                       -- in seconds, So since we delay for 10 seconds, more
                       -- than 20 means there was a gap (likely, computer went
                       -- to sleep, so connection might have been lost). This is
                       -- needed because the IMAP library doesn't seem to detect
                       -- that, and it will continue to report that we are
                       -- "connected" even when we clearly aren't (and will thus
                       -- stop getting push notifications).
                       if diffUTCTime now last > 60
                       then reconnect
                       else return ()
     threadDelay (oneMinute `div` 6)
     reconnectThread super imapid lastchecked cvar


keepAliveThread :: TVar IMAPConnection -> IO ()
keepAliveThread cvar = do threadDelay (9 * oneMinute)
                          conn <- readTVarIO cvar
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
moveMail = do -- 1. Remove duplicates caused by sending to self (anytime it means identical message id).
              files' <- T.lines <$> run "notmuch" ["search",
                                                  "--output=files", "--duplicate=2",
                                                  "folder:inbox", "and",
                                                  "tag:sent"]
              -- NOTE(dbp 2017-04-25): The documentation is unclear; it seems
              -- like the above might return both sometimes, but it seems to
              -- only return the copy that is in the folder: query (so this is
              -- redundant).
              let files = filter (T.isPrefixOf (home <> "/mail/inbox")) files'
              r0 <- case files of
                      [] -> return Noop
                      _ -> do mapM_ (rm . fromText) files
                              run_ "notmuch" ["new", "--quiet"]
                              return SyncAll
              -- 2. Move files to archive that have been archived.
              files <- T.lines <$> run "notmuch" ["search",
                                                  "--output=files",
                                                  "folder:inbox", "and",
                                                  "not", "tag:inbox"]
              r1 <- case files of
                      [] -> return Noop
                      _ -> do mapM_ (\f -> do
                                        target <- getNewName f (home <> "/mail/archive/cur/")
                                        mv (fromText f) (fromText target))
                                files
                              run_ "notmuch" ["new", "--quiet"]
                              return SyncAll
              -- 3. Move files into the inbox that weren't there but have been tagged.
              files <- T.lines <$> run "notmuch" ["search",
                                                  "--output=files",
                                                  "not", "folder:inbox",
                                                  "and", "tag:inbox"]
              r2 <- case files of
                      [] -> return Noop
                      _ -> do mapM_ (\f -> do
                                        target <- getNewName f (home <> "/mail/inbox/cur/")
                                        mv (fromText f) (fromText target))
                                files
                              run_ "notmuch" ["new", "--quiet"]
                              return SyncAll
              return (r0 <> r1 <> r2)

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
                    "tag:unprocessed", "and",
                    "tag:unread"]
  let msgs = fromMaybe [] msgs' :: [Summary]
  when (not $ null msgs) $ liftIO (log' "Notifying of new messages...")
  mapM_ (\(Summary auth sub') ->
           let sub = if "[" `T.isPrefixOf` sub' then T.append "\\" sub' else sub' in
           asyncSh $ run_ "terminal-notifier" ["-message",sub,"-title",auth,"-sender", "org.gnu.Emacs", "-activate", "org.gnu.Emacs", "-timeout", "60"])
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
  capataz <- forkCapataz "main-supervisor" (set onSystemEventL (log' . utf8BuilderToText . display))

  -- forkServer "localhost" 8000
  conn <- connect
  cvar <- newTVarIO conn
  chan <- atomically $ newTBQueue 10
  now <- getCurrentTime
  lastchecked <- newTVarIO now
  let fork nm thunk = forkWorker (buildWorkerOptions nm thunk (set workerRestartStrategyL Permanent)) capataz
  imapid <- fork "imap" $ imapThread chan cvar
  fork "reconnect" $ reconnectThread capataz imapid lastchecked  cvar
  fork "reconnect" $ keepAliveThread cvar
  fork "sync" $ syncThread chan
  fork "files" $ filesThread chan
  fork "periodic" $ periodicThread chan
  finally
    (joinCapatazThread capataz)
    (terminateCapataz_ capataz)
