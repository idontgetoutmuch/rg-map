{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

import Control.Arrow
import Control.Exception (Exception (..))
import Control.Funflow
import Control.Funflow.ContentStore (Content (..), contentItem, itemPath, (^</>))
import qualified Control.Funflow.ContentStore as CS
import qualified Control.Funflow.External.Docker as Docker
import Control.Funflow.External
import Path
import Path.IO
import Control.Funflow.ContentHashable
import Control.Arrow.Free

import System.Posix.Files
import Control.Monad
import Data.Foldable
import Data.Default

main :: IO ()
main = do
    cwd <- getCurrentDir
    r <- withSimpleLocalRunner (cwd </> [reldir|funflow-example/store|]) $ \run ->
      run (mainFlow >>> storePath) ()
    case r of
      Left err ->
        putStrLn $ "FAILED: " ++ displayException err
      Right out -> do
        putStrLn $ "SUCCESS"
        putStrLn $ toFilePath out

-- | This flow takes a number, builds a C program to process that number,
-- and returns the program's output.
mainFlow :: SimpleFlow () (Content Dir)
mainFlow = proc () -> do
  script_dir <- copyDirToStore -< ((DirectoryContent [absdir|/root/map-scraper/scripts/|]), Nothing)

  meta_dir <- step All <<< scrape -< script_dir
  keys <- splitDir -< meta_dir
  maps <- mapA (fetch) -< [( script_dir, event) | event <- keys]
  mapJpgs <- mapA convertToGif -< [(script_dir, m) | m <- maps]
  merge_dir <- mergeDirs' <<< mapA (step All) <<< mapA warp -< [(script_dir, jpg) | jpg <- mapJpgs ]
  vrt_dir <- step All <<< mergeRasters -< (script_dir, merge_dir)
  merged_vrts <- splitDir -< vrt_dir
  tiles <- mergeDirs' <<< mapA (step All) <<< mapA makeTiles -< [(script_dir, vrt) | vrt <- merged_vrts]

  leaflet <- step All <<< makeLeaflet -< ( script_dir, merge_dir, meta_dir)

  mergeDirs -< [leaflet, tiles]


-- Need to mark this as impure
scrape = impureNixScript (\dir -> [contentParam (dir CS.^</> [relfile|scraper.py|]), outParam ])

fetch = nixScript (\(script, metadata) -> [ contentParam (script ^</> [relfile|fetch.py|])
                                          , outParam, contentParam metadata ])

convertToGif = nixScript (\(script, dir) -> [ contentParam (script ^</> [relfile|convert_gif|])
                                            , pathParam (IPItem dir), outParam ])

warp = nixScript (\(script, dir) -> [ contentParam (script ^</> [relfile|do_warp|])
                                    , pathParam (IPItem dir), outParam ])

mergeRasters = nixScript (\(script, dir) -> [ contentParam (script ^</> [relfile|merge-rasters.py|])
                                            , contentParam dir, outParam ])

makeTiles = nixScript (\(script, dir) -> [ contentParam (script ^</> [relfile|make_tiles|])
                                         , contentParam dir, outParam, textParam "16" ])

makeLeaflet = nixScript (\(script, vrt_dir, meta_dir) ->
                [ contentParam (script ^</> [relfile|create-leaflet.py|])
                , contentParam vrt_dir, contentParam meta_dir, textParam "16", outParam ])

nixScript = nixScriptX False

impureNixScript :: ArrowFlow eff ex arr => (a -> [Param]) -> arr a CS.Item
impureNixScript = nixScriptX True

nixScriptX :: ArrowFlow eff ex arr => Bool -> (a -> [Param]) -> arr a CS.Item
nixScriptX impure params =
  external' props $ \args -> ExternalTask
        { _etCommand = "perl"
        , _etParams = params args
        , _etWriteToStdOut = NoOutputCapture
        , _etEnv = [("NIX_PATH", envParam "NIX_PATH")] }
  where
    props = def { ep_impure = impure }



-- | Merge a number of store directories together into a single output directory.
--   This uses hardlinks to avoid duplicating the data on disk.
mergeDirs' :: ArrowFlow eff ex arr => arr [CS.Content Dir] (CS.Content Dir)
mergeDirs' = proc inDirs -> do
  paths <- internalManipulateStore
    ( \store items -> return $ CS.contentPath store <$> items) -< inDirs
  arr CS.All <<< putInStore
    ( \d inDirs -> for_ inDirs $ \inDir -> do
      (subDirs, files) <- listDirRecur inDir
      for_ subDirs $ \absSubDir -> do
        relSubDir <- stripProperPrefix inDir absSubDir
        createDirIfMissing True (d </> relSubDir)
      for_ files $ \absFile -> do
        relFile <- stripProperPrefix inDir absFile
        let target = (toFilePath $ d </> relFile)
        exist <- fileExist target
        when (not exist) (createLink (toFilePath absFile) target)
    ) -< paths

splitDir :: ArrowFlow eff ex arr => arr (Content Dir) ([Content File])
splitDir = proc dir -> do
  (_, fs) <- listDirContents -< dir
  returnA -< fs
--  mapA reifyFile -< fs


-- Put a file, which might be a pointer into a dir, into its own store
-- location.
reifyFile :: ArrowFlow eff ex arr => arr (Content File) (Content File)
reifyFile = proc f -> do
  file <- getFromStore return -< f
  putInStoreAt (\d fn -> copyFile fn d) -< (file, CS.contentFilename f)


storePath :: ArrowFlow eff ex arr => arr (Content Dir) (Path Abs Dir)
storePath = internalManipulateStore (\cs d -> return (CS.itemPath cs (CS.contentItem d)))

copyDirFromStore :: ArrowFlow eff ex arr => Path b1 Dir -> arr (Content Dir) ()
copyDirFromStore dest = getFromStore (\p -> copyDirRecur p dest)
