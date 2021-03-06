{-# LANGUAGE CPP                 #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeFamilies        #-}
module Haskell.Ide.Engine.Plugin.HieExtras
  ( getDynFlags
  , getCompletions
  , getTypeForName
  , getSymbolsAtPoint
  , getReferencesInDoc
  , getModule
  , findDef
  , showName
  , safeTyThingId
  ) where

import           ConLike
import           Control.Monad.State
import           Data.Aeson
import           Data.IORef
import qualified Data.List                                    as List
import qualified Data.Map                                     as Map
import           Data.Maybe
#if __GLASGOW_HASKELL__ < 804
import           Data.Monoid
#endif
import qualified Data.Text                                    as T
import           Data.Typeable
import           DataCon
import           Exception
import           FastString
import           Finder
import           GHC
import qualified GhcMod.Error                                 as GM
import qualified GhcMod.LightGhc                              as GM
import           Haskell.Ide.Engine.ArtifactMap
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import qualified Haskell.Ide.Engine.Plugin.Fuzzy              as Fuzzy
import           HscTypes
import qualified Language.Haskell.LSP.Types                   as J
import           Language.Haskell.Refact.API                 (showGhc)
import           Language.Haskell.Refact.Utils.MonadFunctions
import           Name
import           Outputable                                   (Outputable)
import qualified Outputable                                   as GHC
import qualified DynFlags                                     as GHC
import           Packages
import           SrcLoc
import           TcEnv
import           Var

getDynFlags :: Uri -> IdeM (IdeResponse DynFlags)
getDynFlags uri =
  pluginGetFileResponse "getDynFlags: " uri $ \fp ->
    withCachedModule fp (return . IdeResponseOk . ms_hspp_opts . pm_mod_summary . tm_parsed_module . tcMod)

-- ---------------------------------------------------------------------

data NameMapData = NMD
  { inverseNameMap ::  !(Map.Map Name [SrcSpan])
  } deriving (Typeable)

invert :: (Ord v) => Map.Map k v -> Map.Map v [k]
invert m = Map.fromListWith (++) [(v,[k]) | (k,v) <- Map.toList m]

instance ModuleCache NameMapData where
  cacheDataProducer cm = pure $ NMD inm
    where nm  = initRdrNameMap $ tcMod cm
          inm = invert nm

-- ---------------------------------------------------------------------

data CompItem = CI
  { origName     :: Name
  , importedFrom :: T.Text
  , thingType    :: Maybe T.Text
  , label        :: T.Text
  } deriving (Show)

instance Eq CompItem where
  (CI n1 _ _ _) == (CI n2 _ _ _) = n1 == n2

instance Ord CompItem where
  compare (CI n1 _ _ _) (CI n2 _ _ _) = compare n1 n2

occNameToComKind :: OccName -> J.CompletionItemKind
occNameToComKind oc
  | isVarOcc  oc = J.CiFunction
  | isTcOcc   oc = J.CiClass
  | isDataOcc oc = J.CiConstructor
  | otherwise    = J.CiVariable

type HoogleQuery = T.Text

mkQuery :: T.Text -> T.Text -> HoogleQuery
mkQuery name importedFrom = name <> " module:" <> importedFrom
                                 <> " is:exact"

mkCompl :: CompItem -> J.CompletionItem
mkCompl CI{origName,importedFrom,thingType,label} =
  J.CompletionItem label kind (Just $ maybe "" (<>"\n") thingType <> importedFrom)
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    Nothing Nothing Nothing Nothing hoogleQuery
  where kind  = Just $ occNameToComKind $ occName origName
        hoogleQuery = Just $ toJSON $ mkQuery label importedFrom

mkModCompl :: T.Text -> J.CompletionItem
mkModCompl label =
  J.CompletionItem label (Just J.CiModule) Nothing
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    Nothing Nothing Nothing Nothing hoogleQuery
  where hoogleQuery = Just $ toJSON $ "module:" <> label

safeTyThingId :: TyThing -> Maybe Id
safeTyThingId (AnId i)                    = Just i
safeTyThingId (AConLike (RealDataCon dc)) = Just $ dataConWrapId dc
safeTyThingId _                           = Nothing

-- Associates a module's qualifier with its members
type QualCompls = Map.Map T.Text [CompItem]

data CachedCompletions = CC
  { allModNamesAsNS :: [T.Text]
  , unqualCompls :: [CompItem]
  , qualCompls :: QualCompls
  } deriving (Typeable)

instance ModuleCache CachedCompletions where
  cacheDataProducer cm = do
    let tm = tcMod cm
        parsedMod = tm_parsed_module tm
        curMod = moduleName $ ms_mod $ pm_mod_summary parsedMod
        Just (_,limports,_,_) = tm_renamed_source tm

        iDeclToModName :: ImportDecl name -> ModuleName
        iDeclToModName = unLoc . ideclName

        showModName :: ModuleName -> T.Text
        showModName = T.pack . moduleNameString

#if __GLASGOW_HASKELL__ >= 802
        asNamespace :: ImportDecl name -> ModuleName
        asNamespace imp = fromMaybe (iDeclToModName imp) (fmap GHC.unLoc $ ideclAs imp)
#else
        asNamespace :: ImportDecl name -> ModuleName
        asNamespace imp = fromMaybe (iDeclToModName imp) (ideclAs imp)
#endif
        -- Full canonical names of imported modules
        importDeclerations = map unLoc limports

        -- The given namespaces for the imported modules (ie. full name, or alias if used)
        allModNamesAsNS = map (showModName . asNamespace) importDeclerations

        typeEnv = md_types $ snd $ tm_internals_ tm
        toplevelVars = mapMaybe safeTyThingId $ typeEnvElts typeEnv
        varToCompl var = CI name (showModName curMod) typ label
          where
            typ = Just $ T.pack $ showGhc $ varType var
            name = Var.varName var
            label = T.pack $ showGhc name

        toplevelCompls = map varToCompl toplevelVars

        toCompItem :: ModuleName -> Name -> CompItem
        toCompItem mn n =
          CI n (showModName mn) Nothing (T.pack $ showGhc n)

        allImportsInfo :: [(Bool, T.Text, ModuleName, Maybe (Bool, [Name]))]
        allImportsInfo = map getImpInfo importDeclerations
          where
            getImpInfo imp =
              let modName = iDeclToModName imp
                  modQual = showModName (asNamespace imp)
                  isQual = ideclQualified imp
                  hasHiddsMembers =
                    case ideclHiding imp of
                      Nothing -> Nothing
                      Just (hasHiddens, L _ liens) ->
                        Just (hasHiddens, concatMap (ieNames . unLoc) liens)
              in (isQual, modQual, modName, hasHiddsMembers)

        getModCompls :: GhcMonad m => HscEnv -> m ([CompItem], QualCompls)
        getModCompls hscEnv = do
          (unquals, qualKVs) <- foldM (orgUnqualQual hscEnv) ([], []) allImportsInfo
          return (unquals, Map.fromListWith (++) qualKVs)

        orgUnqualQual hscEnv (prevUnquals, prevQualKVs) (isQual, modQual, modName, hasHiddsMembers) =
          let
            ifUnqual xs = if isQual then prevUnquals else (prevUnquals ++ xs)
            setTypes = setComplsType hscEnv
          in
            case hasHiddsMembers of
              Just (False, members) -> do
                compls <- setTypes (map (toCompItem modName) members)
                return
                  ( ifUnqual compls
                  , (modQual, compls) : prevQualKVs
                  )
              Just (True , members) -> do
                let hiddens = map (toCompItem modName) members
                allCompls <- getComplsFromModName modName
                compls <- setTypes (allCompls List.\\ hiddens)
                return
                  ( ifUnqual compls
                  , (modQual, compls) : prevQualKVs
                  )
              Nothing -> do
                -- debugm $ "///////// Nothing " ++ (show modQual)
                compls <- setTypes =<< getComplsFromModName modName
                return
                  ( ifUnqual compls
                  , (modQual, compls) : prevQualKVs
                  )

        getComplsFromModName :: GhcMonad m
          => ModuleName -> m [CompItem]
        getComplsFromModName mn = do
          mminf <- getModuleInfo =<< findModule mn Nothing
          return $ case mminf of
            Nothing -> []
            Just minf -> map (toCompItem mn) $ modInfoExports minf

        setComplsType :: (Traversable t, MonadIO m)
          => HscEnv -> t CompItem -> m (t CompItem)
        setComplsType hscEnv xs =
          liftIO $ forM xs $ \ci@CI{origName} -> do
            mt <- (Just <$> lookupGlobal hscEnv origName)
                    `catch` \(_ :: SourceError) -> return Nothing
            let typ = do
                  t <- mt
                  tyid <- safeTyThingId t
                  return $ T.pack $ showGhc $ varType tyid
            return $ ci {thingType = typ}

    hscEnvRef <- ghcSession <$> readMTS
    hscEnv <- liftIO $ traverse readIORef hscEnvRef
    (unquals, quals) <- maybe
                          (pure ([], Map.empty))
                          (\env -> GM.runLightGhc env (getModCompls env))
                          hscEnv
    return $ CC
      { allModNamesAsNS = allModNamesAsNS
      , unqualCompls = toplevelCompls ++ unquals
      , qualCompls = quals
      }

getCompletions :: Uri -> (T.Text, T.Text) -> IdeM (IdeResponse [J.CompletionItem])
getCompletions uri (qualifier, ident) = pluginGetFileResponse "getCompletions: " uri $ \file ->
  let handlers =
        [ GM.GHandler $ \(ex :: SomeException) ->
            return $ IdeResponseFail $ IdeError PluginError
                                                (T.pack $ "getCompletions" <> ": " <> (show ex))
                                                Null
        ]
  in flip GM.gcatches handlers $ do
    -- debugm $ "got prefix" ++ show (qualifier, ident)
    let enteredQual = if T.null qualifier then "" else qualifier <> "."
        fullPrefix = enteredQual <> ident
    withCachedModuleAndData file $ \_ CC { allModNamesAsNS, unqualCompls, qualCompls } ->
      let
        filtModNameCompls = map mkModCompl
          $ mapMaybe (T.stripPrefix enteredQual)
          $ Fuzzy.simpleFilter fullPrefix allModNamesAsNS

        filtCompls = Fuzzy.filterBy label ident compls
          where
            compls = if T.null qualifier
              then unqualCompls
              else Map.findWithDefault [] qualifier qualCompls

        in return $ IdeResponseOk $ filtModNameCompls ++ map mkCompl filtCompls

-- ---------------------------------------------------------------------

getTypeForName :: Name -> IdeM (Maybe Type)
getTypeForName n = do
  hscEnvRef <- ghcSession <$> readMTS
  mhscEnv <- liftIO $ traverse readIORef hscEnvRef
  case mhscEnv of
    Nothing -> return Nothing
    Just hscEnv -> do
      mt <- liftIO $ (Just <$> lookupGlobal hscEnv n)
                        `catch` \(_ :: SomeException) -> return Nothing
      return $ fmap varType $ safeTyThingId =<< mt

-- ---------------------------------------------------------------------

getSymbolsAtPoint :: Uri -> Position -> IdeM (IdeResponse [(Range, Name)])
getSymbolsAtPoint uri pos = pluginGetFileResponse "getSymbolsAtPoint: " uri $ \file ->
  withCachedModule file $ return . IdeResponseOk . getSymbolsAtPointPure pos

getSymbolsAtPointPure :: Position -> CachedModule -> [(Range,Name)]
getSymbolsAtPointPure pos cm = maybe [] (`getArtifactsAtPos` locMap cm) $ newPosToOld cm pos

symbolFromTypecheckedModule
  :: LocMap
  -> Position
  -> Maybe (Range, Name)
symbolFromTypecheckedModule lm pos =
  case getArtifactsAtPos pos lm of
    (x:_) -> pure x
    []    -> Nothing

-- ---------------------------------------------------------------------

-- | Find the references in the given doc, provided it has been
-- loaded.  If not, return the empty list.
getReferencesInDoc :: Uri -> Position -> IdeM (IdeResponse [J.DocumentHighlight])
getReferencesInDoc uri pos =
  pluginGetFileResponse "getReferencesInDoc: " uri $ \file ->
    withCachedModuleAndDataDefault file (Just (IdeResponseOk [])) $
      \cm NMD{inverseNameMap} -> do
        let lm = locMap cm
            pm = tm_parsed_module $ tcMod cm
            cfile = ml_hs_file $ ms_location $ pm_mod_summary pm
            mpos = newPosToOld cm pos
        case mpos of
          Nothing -> return $ IdeResponseOk []
          Just pos' -> return $ fmap concat $
            forM (getArtifactsAtPos pos' lm) $ \(_,name) -> do
                let usages = fromMaybe [] $ Map.lookup name inverseNameMap
                    defn = nameSrcSpan name
                    defnInSameFile =
                      (unpackFS <$> srcSpanFileName_maybe defn) == cfile
                    makeDocHighlight :: SrcSpan -> Maybe J.DocumentHighlight
                    makeDocHighlight spn = do
                      let kind = if spn == defn then J.HkWrite else J.HkRead
                      let
                        foo (Left _) = Nothing
                        foo (Right r) = Just r
                      r <- foo $ srcSpan2Range spn
                      r' <- oldRangeToNew cm r
                      return $ J.DocumentHighlight r' (Just kind)
                    highlights
                      |    isVarOcc (occName name)
                        && defnInSameFile = mapMaybe makeDocHighlight (defn : usages)
                      | otherwise = mapMaybe makeDocHighlight usages
                return highlights

-- ---------------------------------------------------------------------

showName :: Outputable a => a -> T.Text
showName = T.pack . prettyprint
  where
    prettyprint x = GHC.renderWithStyle GHC.unsafeGlobalDynFlags (GHC.ppr x) style
#if __GLASGOW_HASKELL__ >= 802
    style = (GHC.mkUserStyle GHC.unsafeGlobalDynFlags GHC.neverQualify GHC.AllTheWay)
#else
    style = (GHC.mkUserStyle GHC.neverQualify GHC.AllTheWay)
#endif

getModule :: DynFlags -> Name -> Maybe (Maybe T.Text,T.Text)
getModule df n = do
  m <- nameModule_maybe n
  let uid = moduleUnitId m
  let pkg = showName . packageName <$> lookupPackage df uid
  return (pkg, T.pack $ moduleNameString $ moduleName m)

-- ---------------------------------------------------------------------

-- | Return the definition
findDef :: Uri -> Position -> IdeM (IdeResponse [Location])
findDef uri pos = pluginGetFileResponse "findDef: " uri $ \file ->
    withCachedModuleDefault file (Just (IdeResponseOk [])) (\cm -> do
      let rfm = revMap cm
          lm = locMap cm
          mm = moduleMap cm
          oldPos = newPosToOld cm pos

      case (\x -> Just $ getArtifactsAtPos x mm) =<< oldPos of
        Just ((_,mn):_) -> gotoModule rfm mn
        _ -> case symbolFromTypecheckedModule lm =<< oldPos of
          Nothing -> return $ IdeResponseOk []
          Just (_, n) ->
            case nameSrcSpan n of
              UnhelpfulSpan _ -> return $ IdeResponseOk []
              realSpan   -> do
                res <- srcSpan2Loc rfm realSpan
                case res of
                  Right l@(J.Location luri range) ->
                    case uriToFilePath luri of
                      Nothing -> return $ IdeResponseOk [l]
                      Just fp -> do
                        mcm' <- getCachedModule fp
                        case mcm' of
                          ModuleCached cm' _ ->  case oldRangeToNew cm' range of
                            Just r  -> return $ IdeResponseOk [J.Location luri r]
                            Nothing -> return $ IdeResponseOk [l]
                          _ -> return $ IdeResponseOk [l]
                  Left x -> do
                    debugm "findDef: name srcspan not found/valid"
                    pure (IdeResponseFail
                          (IdeError PluginError
                                    ("hare:findDef" <> ": \"" <> x <> "\"")
                                    Null)))
  where
    gotoModule :: (FilePath -> FilePath) -> ModuleName -> IdeM (IdeResponse [Location])
    gotoModule rfm mn = do
      
      hscEnvRef <- ghcSession <$> readMTS
      mHscEnv <- liftIO $ traverse readIORef hscEnvRef

      case mHscEnv of
        Just env -> do
          fr <- liftIO $ do
            -- Flush cache or else we get temporary files
            flushFinderCaches env
            findImportedModule env mn Nothing
          case fr of
            Found (ModLocation (Just src) _ _) _ -> do
              fp <- reverseMapFile rfm src

              let r = Range (Position 0 0) (Position 0 0)
                  loc = Location (filePathToUri fp) r
              return (IdeResponseOk [loc])
            _ -> return (IdeResponseOk [])
        Nothing -> return $ IdeResponseFail
          (IdeError PluginError "Couldn't get hscEnv when finding import" Null)

