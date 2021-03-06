{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleContexts #-}

module Dang.IO (
    loadFile
  , withROFile
  , withROBinaryFile
  , withWOBinaryFile
  , withClosedTempFile
  , withOpenTempFile
  , E.IOException

  , onFileNotFound

  , whenVerbosity
  , logInfo, logStage
  , logDebug
  , logError
  ) where

import Colors
import Dang.Monad

import MonadLib
import System.Directory
import System.IO
import System.IO.Error
import qualified Control.Exception as E
import qualified Data.Text.Lazy    as L
import qualified Data.Text.Lazy.IO as L


-- | Read in a file as a strict ByteString.
loadFile :: BaseM m Dang => FilePath -> m L.Text
loadFile path = do
  logInfo ("load file: " ++ path)
  io (L.readFile path)

onFileNotFound :: RunExceptionM m SomeException
               => m a -> (E.IOException -> FilePath -> m a) -> m a
onFileNotFound m = catchJustE p m . uncurry
  where
  p e = do
    guard (isDoesNotExistError e)
    path <- ioeGetFileName e
    return (e,path)

dangTempDir :: FilePath
dangTempDir  = "/tmp/dang"

ensureTempDir :: BaseM m Dang => m ()
ensureTempDir  = io (createDirectoryIfMissing True dangTempDir)

ensureClosed :: BaseM m Dang => Handle -> m ()
ensureClosed h = io $ do
  b <- hIsClosed h
  unless b $ do
    hFlush h
    hClose h

withROFile :: BaseM m Dang => FilePath -> (Handle -> m a) -> m a
withROFile path k = do
  logInfo ("read file: " ++ path)
  h   <- io (openFile path ReadMode)
  res <- k h
  ensureClosed h
  return res

withROBinaryFile :: BaseM m Dang => FilePath -> (Handle -> m a) -> m a
withROBinaryFile path k = do
  logInfo ("read file[b]: " ++ path)
  h   <- io (openBinaryFile path ReadMode)
  res <- k h
  ensureClosed h
  return res

withWOBinaryFile :: BaseM m Dang => FilePath -> (Handle -> m a) -> m a
withWOBinaryFile path k = do
  logInfo ("write file[b]: " ++ path)
  h   <- io (openBinaryFile path WriteMode)
  res <- k h
  ensureClosed h
  return res

withOpenTempFile :: BaseM m Dang => (FilePath -> Handle -> m a) -> m a
withOpenTempFile k = do
  ensureTempDir
  (path,h) <- io (openTempFile "/tmp/dang" "dang.tmp")
  logInfo ("temp file: " ++ path)
  res      <- k path h
  ensureClosed h
  opts     <- getOptions
  unless (optKeepTempFiles opts) $ do
    logInfo ("removing: " ++ path)
    io (removeFile path)
  return res

withClosedTempFile :: BaseM m Dang => (FilePath -> m a) -> m a
withClosedTempFile k = withOpenTempFile $ \path h -> do
  io (hClose h)
  k path


-- Logging ---------------------------------------------------------------------

whenVerbosity :: BaseM m Dang => Verbosity -> m () -> m ()
whenVerbosity v m = do
  opts <- getOptions
  when (optVerbosity opts >= v) m

logString :: BaseM m Dang => (String -> String) -> String -> String -> m ()
logString mode label str =
  io $ putStrLn $ showString (mode ('[' : label ++ "]")) $ showChar '\t' str

logError :: BaseM m Dang => String -> m ()
logError  = whenVerbosity 0
          . logString (withGraphics [fg red, bold]) "ERROR"

logInfo :: BaseM m Dang => String -> m ()
logInfo  = whenVerbosity 1
         . logString (withGraphics [fg cyan, bold]) "INFO"

logDebug :: BaseM m Dang => String -> m ()
logDebug  = whenVerbosity 2
          . logString (withGraphics [fg blue, bold]) "DEBUG"

logStage :: BaseM m Dang => String -> m ()
logStage l = whenVerbosity 1 (io (putStrLn msg))
  where
  msg  = concat
       [ withGraphics [fg blue, bold] "--{"
       , withGraphics [fg cyan, bold] l
       , withGraphics [fg blue, bold] ('}' : line) ]
  line = replicate (80 - length l - 4) '-'
