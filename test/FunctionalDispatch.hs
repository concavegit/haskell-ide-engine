{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}

{-

Start up an actual instance of the HIE server, and interact with it.

The startup code is based on that in MainHie.hs

TODO: extract the commonality

-}
module FunctionalDispatch (dispatchSpec) where

import           Control.Concurrent
import           Control.Concurrent.STM.TChan
import           Control.Concurrent.STM.TVar
import           Control.Monad
import           Control.Monad.STM
import           Data.Aeson
import qualified Data.HashMap.Strict                   as H
import qualified Data.Map                              as Map
import qualified Data.Set                              as S
import qualified Data.Text                             as T
import           Data.Typeable
import           Data.Default
import           GHC.Generics
import           Haskell.Ide.Engine.Dispatcher
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.PluginUtils
import           Haskell.Ide.Engine.Types
import           Language.Haskell.LSP.Types hiding (error)
import           System.Directory
import           System.FilePath
import           TestUtils

import           Test.Hspec

-- ---------------------------------------------------------------------
-- plugins

import           Haskell.Ide.Engine.Plugin.ApplyRefact
import           Haskell.Ide.Engine.Plugin.Base
import           Haskell.Ide.Engine.Plugin.Example2
import           Haskell.Ide.Engine.Plugin.GhcMod
import           Haskell.Ide.Engine.Plugin.HaRe
import           Haskell.Ide.Engine.Plugin.HieExtras

{-# ANN module ("HLint: ignore Redundant do"       :: String) #-}
-- ---------------------------------------------------------------------

plugins :: IdePlugins
plugins = pluginDescToIdePlugins
  [("applyrefact", applyRefactDescriptor)
  ,("eg2"        , example2Descriptor)
  ,("ghcmod"     , ghcmodDescriptor)
  ,("hare"       , hareDescriptor)
  ,("base"       , baseDescriptor)
  ]

startServer :: IO (TChan (PluginRequest IO),TChan LogVal)
startServer = do
  cin      <- atomically newTChan
  logChan  <- atomically newTChan

  cancelTVar      <- atomically $ newTVar S.empty
  wipTVar         <- atomically $ newTVar S.empty
  versionTVar     <- atomically $ newTVar Map.empty
  let dispatcherEnv = DispatcherEnv
        { cancelReqsTVar     = cancelTVar
        , wipReqsTVar        = wipTVar
        , docVersionTVar     = versionTVar
        }

  void $ forkIO $ dispatcherP cin plugins testOptions dispatcherEnv
                    (\lid errCode e -> logToChan logChan ("received an error", Left (lid, errCode, e)))
                    (\g x -> g x)
                    def
  return (cin,logChan)

-- ---------------------------------------------------------------------

type LogVal = (String, Either (LspId, ErrorCode, T.Text) DynamicJSON)

logToChan :: TChan LogVal -> LogVal -> IO ()
logToChan c t = atomically $ writeTChan c t

-- ---------------------------------------------------------------------

dispatchGhcRequest :: ToJSON a
                   => TrackingNumber -> String -> Int
                   -> TChan (PluginRequest IO) -> TChan LogVal
                   -> PluginId -> CommandName -> a -> IO ()
dispatchGhcRequest tn ctx n cin lc plugin com arg = do
  let
    logger :: RequestCallback IO DynamicJSON
    logger x = logToChan lc (ctx, Right x)

  let req = GReq tn Nothing Nothing (Just (IdInt n)) logger $
        runPluginCommand plugin com (toJSON arg)
  atomically $ writeTChan cin req

dispatchIdeRequest :: (Typeable a, ToJSON a)
                   => TrackingNumber -> String -> TChan (PluginRequest IO)
                   -> TChan LogVal -> LspId -> IdeM (IdeResponse a) -> IO () 
dispatchIdeRequest tn ctx cin lc lid f = do
  let
    logger :: (Typeable a, ToJSON a) => RequestCallback IO a
    logger x = logToChan lc (ctx, Right (toDynJSON x))

  let req = IReq tn lid logger f
  atomically $ writeTChan cin req

-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------

data Cached = Cached | NotCached deriving (Show,Eq,Generic)

-- Don't care instances via GHC.Generic
instance FromJSON Cached where
instance ToJSON   Cached where

-- ---------------------------------------------------------------------

dispatchSpec :: Spec
dispatchSpec = do
  (cin,logChan) <- runIO startServer
  cwd <- runIO getCurrentDirectory
  let testUri = filePathToUri $ cwd </> "FuncTest.hs"

  let
    -- Model a hover request
    hoverReq tn idVal doc = dispatchIdeRequest tn ("IReq " ++ show idVal) cin logChan idVal $ do
      pluginGetFileResponse ("hoverReq") doc $ \fp -> do
        cached <- isCached fp
        if cached
          then return (IdeResponseOk Cached)
          else return (IdeResponseOk NotCached)

    unpackRes (r,Right md) = (r, fromDynJSON md)
    unpackRes r            = error $ "unpackRes:" ++ show r
    
  
  describe "dispatch" $ do
    it "defers responses until module is loaded" $ do

      -- Returns immediately, no cached value
      hoverReq 0 (IdInt 0) testUri
      hr0 <- atomically $ readTChan logChan
      unpackRes hr0 `shouldBe` ("IReq IdInt 0",Just NotCached)

      -- This request should be deferred, only return when the module is loaded
      dispatchIdeRequest 1 "req1" cin logChan (IdInt 1) $ getSymbols testUri

      rrr <- atomically $ tryReadTChan logChan
      (show rrr) `shouldBe` "Nothing"

      -- need to typecheck the module to trigger deferred response
      dispatchGhcRequest 2 "req2" 2 cin logChan "ghcmod" "check" (toJSON testUri)

      -- And now we get the deferred response (once the module is loaded)
      ("req1",Right res) <- atomically $ readTChan logChan
      let Just ss = fromDynJSON res :: Maybe [SymbolInformation]
      head ss `shouldBe`
                  SymbolInformation
                     { _name          = "main"
                     , _kind          = SkFunction
                     , _location      = Location
                       { _uri   = testUri
                       , _range = Range
                         { _start = Position {_line = 2, _character = 0}
                         , _end   = Position {_line = 2, _character = 4}
                         }
                       }
                     , _containerName = Nothing
                     }

      -- followed by the diagnostics ...
      ("req2",Right res2) <- atomically $ readTChan logChan
      show res2 `shouldBe` "((Map Uri (Set Diagnostic)),[Text])"

      -- No more pending results
      rr3 <- atomically $ tryReadTChan logChan
      (show rr3) `shouldBe` "Nothing"

      -- Returns immediately, there is a cached value
      hoverReq 3 (IdInt 3) testUri
      hr3 <- atomically $ readTChan logChan
      unpackRes hr3 `shouldBe` ("IReq IdInt 3",Just Cached)

    it "instantly responds to deferred requests if cache is available" $ do
      -- deferred responses should return something now immediately
      -- as long as the above test ran before
      dispatchIdeRequest 0 "references" cin logChan (IdInt 4)
        $ getReferencesInDoc testUri (Position 7 0)

      hr4 <- atomically $ readTChan logChan
      -- show hr4 `shouldBe` "hr4"
      unpackRes hr4 `shouldBe` ("references",Just
                   [ DocumentHighlight
                     { _range = Range
                       { _start = Position {_line = 7, _character = 0}
                       , _end   = Position {_line = 7, _character = 2}
                       }
                     , _kind  = Just HkWrite
                     }
                   , DocumentHighlight
                     { _range = Range
                       { _start = Position {_line = 7, _character = 0}
                       , _end   = Position {_line = 7, _character = 2}
                       }
                     , _kind  = Just HkWrite
                     }
                   , DocumentHighlight
                     { _range = Range
                       { _start = Position {_line = 5, _character = 6}
                       , _end   = Position {_line = 5, _character = 8}
                       }
                     , _kind  = Just HkRead
                     }
                   , DocumentHighlight
                     { _range = Range
                       { _start = Position {_line = 7, _character = 0}
                       , _end   = Position {_line = 7, _character = 2}
                       }
                     , _kind  = Just HkWrite
                     }
                   , DocumentHighlight
                     { _range = Range
                       { _start = Position {_line = 7, _character = 0}
                       , _end   = Position {_line = 7, _character = 2}
                       }
                     , _kind  = Just HkWrite
                     }
                   , DocumentHighlight
                     { _range = Range
                       { _start = Position {_line = 5, _character = 6}
                       , _end   = Position {_line = 5, _character = 8}
                       }
                     , _kind  = Just HkRead
                     }
                   ])

    it "returns hints as diagnostics" $ do

      dispatchGhcRequest 5 "r5" 5 cin logChan "applyrefact" "lint" testUri

      hr5 <- atomically $ readTChan logChan
      unpackRes hr5 `shouldBe` ("r5",
             Just $ PublishDiagnosticsParams
                     { _uri         = filePathToUri $ cwd </> "FuncTest.hs"
                     , _diagnostics = List
                       [ Diagnostic
                           (Range (Position 9 6) (Position 10 18))
                           (Just DsInfo)
                           (Just "Redundant do")
                           (Just "hlint")
                           "Redundant do\nFound:\n  do putStrLn \"hello\"\nWhy not:\n  putStrLn \"hello\"\n"
                           Nothing
                       ]
                     }
                   )

      let req6 = HP testUri (toPos (8, 1))
      dispatchGhcRequest 6 "r6" 6 cin logChan "hare" "demote" req6

      hr6 <- atomically $ readTChan logChan
      -- show hr6 `shouldBe` "hr6"
      let textEdits = List [TextEdit (Range (Position 6 0) (Position 7 6)) "  where\n    bb = 5"]
          r6uri = filePathToUri $ cwd </> "FuncTest.hs"
      unpackRes hr6 `shouldBe` ("r6",Just
        (WorkspaceEdit
          (Just $ H.singleton r6uri textEdits)
          Nothing
        ))
    
    it "instantly responds to failed modules with no cache" $ do

      let failUri = filePathToUri $ cwd </> "FuncTestFail.hs"

      dispatchIdeRequest 7 "req7" cin logChan (IdInt 7) $ getSymbols failUri

      dispatchGhcRequest 8 "req8" 8 cin logChan "ghcmod" "check" (toJSON failUri)

      (_, Left symbolError) <- atomically $ readTChan logChan
      symbolError `shouldBe` (IdInt 7, ParseError, "")

      ("req8", Right diags) <- atomically $ readTChan logChan
      show diags `shouldBe` "((Map Uri (Set Diagnostic)),[Text])"

