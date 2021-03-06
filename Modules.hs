{-# LANGUAGE FlexibleContexts #-}
module Modules where

import System.Environment
import System.Directory
import Control.Monad.State
import Control.Monad.IO.Class
import Control.Monad.Except hiding (void, fail)
import Data.List
import Data.Char
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified AST as S
import qualified Parser as P
import qualified Lexer as L
import Flatten
import Monad
import Error
import JIT
import Compile
import CompileState
import Args


data Modules
    = Modules
        { modMap  :: Map.Map S.Path CompileState
        , session :: JIT.Session
        }


initModulesState session
    = Modules
        { modMap  = Map.empty
        , session = session
        }


showPath :: S.Path -> String
showPath path = concat (intersperse "/" path)


parse :: BoM s m => Int -> FilePath -> m S.AST
parse id file = do
    source <- liftIO (readFile file)
    case P.parse id source of
        Left (ErrorStr str)         -> throwError (ErrorStr str)
        Left (ErrorFile "" pos str) -> throwError (ErrorFile file pos str)
        Right a                     -> return a


runMod :: BoM Modules m => Args -> Set.Set S.Path -> S.Path -> m CompileState
runMod args visited modPath = do
    debug "running"

    path <- resolvePath modPath
    let (dir, name) = (init path, last path)

    when (Set.member path visited) $
        fail ("importing \"" ++ showPath path ++ "\" forms a cycle")

    res <- Map.lookup path <$> gets modMap
    case res of
        Just state -> return state
        Nothing    -> do
            files <- getSpecificModuleFiles name =<< getBoFilesInDirectory (if null dir then "." else showPath dir)
            when (null files) $ fail ("no files for: " ++ showPath path)

            asts <- forM (zip files [0..]) $ \(file, id) -> do
                debug ("using file: " ++ file)
                parse id file

            -- flatten asts
            combinedAST <- combineASTs asts
            imports <- fmap Map.fromList $ forM (S.astImports combinedAST) $ \importPath -> do
                resPath <- resolvePath (dir ++ importPath)
                debug ("importing : " ++ showPath importPath)
                state <- runMod args (Set.insert path visited) resPath
                return (importPath, state)

            flatRes <- runBoMT initFlattenState (flattenAST combinedAST)
            flat <- case flatRes of
                Left (ErrorFile "" pos str) -> throwError $ ErrorFile (files !! textFile pos) pos str
                Right ((), flatState)       -> return flatState

            -- compile and run
            debug "compiling"
            session <- gets session
            cmpRes <- runBoMT () $ compileFlatState (JIT.context session) (JIT.dataLayout session) imports flat
            state <- case cmpRes of
                Left (ErrorFile "" pos str) -> throwError $ ErrorFile (files !! textFile pos) pos str
                Left (ErrorStr str)         -> throwError $ ErrorStr str
                Right (s, _)                -> return s

            liftIO $ jitAndRun (definitions state) session True (printLLIR args) 
            modify $ \s -> s { modMap = Map.insert path state (modMap s) }
            return state


    where
        debug str =
            if verbose args
            then liftIO $ putStrLn (showPath modPath ++ " -> " ++ str)
            else return ()


resolvePath :: BoM s m => S.Path -> m S.Path
resolvePath path = case path of
    ("..":_)    -> fail ("cannot resolve directory: " ++ showPath path)
    (x:"..":xs) -> resolvePath xs
    (".":xs)    -> resolvePath xs
    (x:xs)      -> (x:) <$> resolvePath xs
    _           -> return []


getBoFilesInDirectory :: BoM s m => FilePath -> m [FilePath]
getBoFilesInDirectory dir = do
    list <- liftIO (listDirectory dir)
    return [ dir ++ "/" ++ f | f <- list, isSuffixOf ".bo" f ]


getSpecificModuleFiles :: BoM s m => String -> [FilePath] -> m [FilePath]
getSpecificModuleFiles name []     = return []
getSpecificModuleFiles name (f:fs) = do
    source <- liftIO (readFile f)
    ast <- parse 0 f
    if fromJust (S.astModuleName ast) == name then
        (f:) <$> getSpecificModuleFiles name fs
    else
        getSpecificModuleFiles name fs

