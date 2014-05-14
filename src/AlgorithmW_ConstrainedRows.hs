----------------------------------------------------------------------
-- Polymorphic Extensible Records and Variants with Constrained Rows
----------------------------------------------------------------------

{-# LANGUAGE TupleSections, OverloadedStrings, ViewPatterns #-}

module AlgorithmW_ConstrainedRows where

import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Set as S

import Control.Applicative ((<$>))
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State
import Data.String
import Text.PrettyPrint.Leijen hiding ((<$>))

type Name  = String
type Label = String

data Exp
  = EVar  Name
  | EPrim Prim
  | EApp  Exp Exp
  | EAbs  Name Exp
  | ELet  Name Exp Exp

data Prim
  = Int Integer
  | Bool Bool
  | RecordSelect Label
  | RecordExtend Label
  | RecordRestrict Label
  | RecordEmpty
    deriving (Eq, Ord)

data Type
  = TVar TyVar
  | TInt
  | TBool
  | TFun Type Type
  | TRecord Type
  | TRowEmpty
  | TRowExtend Label Type Type
    deriving (Eq, Ord)

data TyVar = TyVar
  { tyvarName       :: Name
  , tyvarConstraint :: Constraint
  } deriving (Eq, Ord)

data Constraint
  = CRowLacks (S.Set Label)
  | CNone
    deriving (Eq, Ord)

data Scheme = Scheme [TyVar] Type

class Types a where
  ftv :: a -> S.Set TyVar -- ^ free type variables
  apply :: Subst -> a -> a

instance Types Type where
  ftv (TVar v) = S.singleton v
  ftv TInt = S.empty
  ftv TBool = S.empty
  ftv (TFun t1 t2) = ftv t1 `S.union` ftv t2
  ftv (TRecord t) = ftv t
  ftv TRowEmpty = S.empty
  ftv (TRowExtend l t r) = ftv r `S.union` ftv t
  apply s (TVar v) = case M.lookup v s of
                       Nothing -> TVar v
                       Just t -> t
  apply s (TFun t1 t2) = TFun (apply s t1) (apply s t2)
  apply s (TRecord t) = TRecord (apply s t)
  apply s (TRowExtend l t r) = TRowExtend l (apply s t) (apply s r)
  apply s t = t

instance Types Scheme where
  ftv (Scheme vars t) = (ftv t) S.\\ (S.fromList vars)
  apply s (Scheme vars t) = Scheme vars (apply (foldr M.delete s vars) t)

instance Types a => Types [a] where
  apply s = map (apply s)
  ftv l = foldr S.union S.empty (map ftv l)

type Subst = M.Map TyVar Type

nullSubst :: Subst
nullSubst = M.empty

-- | apply s1 and then s2
-- NB: order is very important, there were bugs in the original
-- "Algorithm W Step-by-Step" paper related to substitution composition
composeSubst :: Subst -> Subst -> Subst
composeSubst s1 s2 = (M.map (apply s1) s2) `M.union` s1

newtype TypeEnv = TypeEnv (M.Map Name Scheme)

remove :: TypeEnv -> Name -> TypeEnv
remove (TypeEnv env) var = TypeEnv (M.delete var env)

instance Types TypeEnv where
  ftv (TypeEnv env) = ftv (M.elems env)
  apply s (TypeEnv env) = TypeEnv (M.map (apply s) env)

-- | generalise abstracts a type over all type variables which are free
-- in the type but not free in the given type environment.
generalise :: TypeEnv -> Type -> Scheme
generalise env t = Scheme vars t
  where
    vars = S.toList ((ftv t) S.\\ (ftv env))

data TIEnv = TIEnv {}
data TIState = TIState {tiSupply :: Int, tiSubst :: Subst }

type TI a = ErrorT String (ReaderT TIEnv (StateT TIState IO)) a

runTI :: TI a -> IO (Either String a, TIState)
runTI t = do
  (res, st) <- runStateT (runReaderT (runErrorT t) initTIEnv) initTIState
  return (res, st)
  where
    initTIEnv = TIEnv {}

initTIState = TIState {tiSupply = 0, tiSubst = M.empty }

newTyVar :: Char -> TI Type
newTyVar = newTyVarWith CNone

newTyVarWith :: Constraint -> Char -> TI Type
newTyVarWith c prefix = do
  s <- get
  put s {tiSupply = tiSupply s + 1 }
  let name = prefix : show (tiSupply s)
  return (TVar $ TyVar name c)

-- | The instantiation function replaces all bound type variables in a
-- type scheme with fresh type variables.
instantiate :: Scheme -> TI Type
instantiate (Scheme vars t) = do
  nvars <- mapM (\(TyVar (p:_) c) -> newTyVarWith c p) vars
  let s = M.fromList (zip vars nvars)
  return $ apply s t

unify :: Type -> Type -> TI Subst
unify (TFun l r) (TFun l' r') = do
  s1 <- unify l l'
  s2 <- unify (apply s1 r) (apply s1 r')
  return $ s2 `composeSubst` s1
unify (TVar u) (TVar v) = unionConstraints u v
unify (TVar v) t = varBind v t
unify t (TVar v) = varBind v t
unify TInt TInt = return nullSubst
unify TBool TBool = return nullSubst
unify (TRecord row1) (TRecord row2) = unify row1 row2
unify TRowEmpty TRowEmpty = return nullSubst
unify (TRowExtend label1 fieldTy1 rowTail1) row2@TRowExtend{} = do
  (fieldTy2, rowTail2, theta1) <- rewriteRow row2 label1
  -- ^ apply side-condition to ensure termination
  case snd $ toList rowTail2 of
    Just tv | M.member tv theta1 -> throwError "recursive row type"
    _ -> do
      theta2 <- unify (apply theta1 fieldTy1) (apply theta1 fieldTy2)
      let s = theta2 `composeSubst` theta1
      theta3 <- unify (apply s rowTail1) (apply s rowTail2)
      return $ theta3 `composeSubst` s
unify t1 t2 = throwError $ "types do not unify: " ++ show t1 ++ " vs. " ++ show t2

unionConstraints :: TyVar -> TyVar -> TI Subst
unionConstraints u v
  | u == v    = return nullSubst
  | CNone <- tyvarConstraint u
  , CNone <- tyvarConstraint v = return $ M.singleton u (TVar v)
  | otherwise = do
      let c = CRowLacks $ (labelsFromTyVar u) `S.union` (labelsFromTyVar v)
      r <- newTyVarWith c 'r'
      return $ M.fromList [ (u, r), (v, r) ]

varBind :: TyVar -> Type -> TI Subst
varBind u t
  | u `S.member` ftv t = throwError $ "occur check fails: " ++ " vs. " ++ show t
  | otherwise          = case tyvarConstraint u of
                           CNone        -> return $ M.singleton u t
                           CRowLacks ls -> constrainRow ls u t

constrainRow :: S.Set Label -> TyVar -> Type -> TI Subst
constrainRow ls u t
  = case S.toList (ls `S.intersection` ls') of
      []     -> case mv of
                  Nothing -> return s1
                  Just r1 -> do
                    let c = CRowLacks $ ls `S.union` (labelsFromTyVar r1)
                    r2 <- newTyVarWith c 'r'
                    let s2 = M.singleton r1 r2
                    return $ s1 `composeSubst` s2
      labels -> throwError $ "repeated labels: " ++ show labels
  where
    (S.fromList . map fst -> ls', mv) = toList t
    s1                                = M.singleton u t

rewriteRow :: Type -> Label -> TI (Type, Type, Subst)
rewriteRow TRowEmpty newLabel = throwError $ "label " ++ newLabel ++ " cannot be inserted"
rewriteRow (TRowExtend label fieldTy rowTail) newLabel
  | newLabel == label     = return (fieldTy, rowTail, nullSubst) -- ^ nothing to do
  | TVar alpha <- rowTail
  , ls <- labelsFromTyVar alpha
    = case newLabel `S.notMember` ls of
        True  -> do
          let c = CRowLacks $ S.insert newLabel ls
          beta  <- newTyVarWith c 'r'
          gamma <- newTyVar 'a'
          return ( gamma
                 , TRowExtend label fieldTy beta
                 , M.singleton alpha $ TRowExtend newLabel gamma beta
                 )
        False -> throwError $ "repeated label: " ++ show newLabel
  | otherwise   = do
      (fieldTy', rowTail', s) <- rewriteRow rowTail newLabel
      return ( fieldTy'
             , TRowExtend label fieldTy rowTail'
             , s
             )
rewriteRow ty _ = error $ "Unexpected type: " ++ show ty

-- | type-inference
ti :: TypeEnv -> Exp -> TI (Subst, Type)
ti (TypeEnv env) (EVar n) =
  case M.lookup n env of
    Nothing -> throwError $ "unbound variable: "++n
    Just sigma -> do
      t <- instantiate sigma
      return (nullSubst, t)
ti env (EPrim prim) = (nullSubst,) <$> tiPrim prim
ti env (EAbs n e) = do
  tv <- newTyVar 'a'
  let TypeEnv env' = remove env n
      env'' = TypeEnv (env' `M.union` (M.singleton n (Scheme [] tv)))
  (s1, t1) <- ti env'' e
  return (s1, TFun (apply s1 tv) t1)
ti env (EApp e1 e2) = do
  (s1, t1) <- ti env e1
  (s2, t2) <- ti (apply s1 env) e2
  tv <- newTyVar 'a'
  s3 <- unify (apply s2 t1) (TFun t2 tv)
  return (s3 `composeSubst` s2 `composeSubst` s1, apply s3 tv)
ti env (ELet x e1 e2) = do
  (s1, t1) <- ti env e1
  let TypeEnv env' = remove env x
      scheme = generalise (apply s1 env) t1
      env''  = TypeEnv (M.insert x scheme env')
  (s2, t2) <- ti (apply s1 env'') e2
  return (s2 `composeSubst` s1, t2)

tiPrim :: Prim -> TI Type
tiPrim p = case p of
  (Int _)                -> return TInt
  (Bool _)               -> return TBool
  RecordEmpty            -> return $ TRecord TRowEmpty
  (RecordSelect label)   -> do
    a <- newTyVar 'a'
    r <- newTyVarWith (lacks label) 'r'
    return $ TFun (TRecord $ TRowExtend label a r) a
  (RecordExtend label)   -> do
    a <- newTyVar 'a'
    r <- newTyVarWith (lacks label) 'r'
    return $ TFun a (TFun (TRecord r) (TRecord $ TRowExtend label a r))
  (RecordRestrict label) -> do
    a <- newTyVar 'a'
    r <- newTyVarWith (lacks label) 'r'
    return $ TFun (TRecord $ TRowExtend label a r) (TRecord r)

typeInference :: M.Map String Scheme -> Exp -> TI Type
typeInference env e = do
  (s, t) <- ti (TypeEnv env) e
  return $ apply s t

--  | decompose a row-type into its constituent parts
toList :: Type -> ([(Label, Type)], Maybe TyVar)
toList (TVar v)           = ([], Just v)
toList TRowEmpty          = ([], Nothing)
toList (TRowExtend l t r) = let (ls, mv) = toList r
                            in ((l, t):ls, mv)
lacks :: Label -> Constraint
lacks = CRowLacks . S.singleton

labelsFromTyVar :: TyVar -> S.Set Label
labelsFromTyVar v = case tyvarConstraint v of
                      CNone        -> S.empty
                      CRowLacks ls -> ls


----------------------------------------------------------------------
-- Examples

e1 = EApp (EApp (EPrim $ RecordExtend "y") (EPrim $ Int 2)) (EPrim RecordEmpty)
e2 = EApp (EApp (EPrim $ RecordExtend "x") (EPrim $ Int 1)) e1
e3 = EApp (EPrim $ RecordSelect "y") e2
e4 = ELet "f" (EAbs "r" (EApp (EPrim $ RecordSelect "x") (EVar "r"))) (EVar "f")
e5 = (EAbs "r" (EApp (EPrim $ RecordSelect "x") (EVar "r")))

test :: Exp -> IO ()
test e = do
  (res,_) <- runTI $ typeInference M.empty e
  case res of
    Left err -> putStrLn $ "error: " ++ err
    Right t  -> putStrLn $ show e ++ " :: " ++ show (generalise (TypeEnv M.empty) t)

main :: IO ()
main = do
  mapM test [ e1, e2, e3, e4, e5 ]
  return ()


------------------------------------------------------------
-- Pretty-printing

instance IsString Doc where
  fromString = text

instance Show Type where
  showsPrec _ x = shows $ ppType x

ppType :: Type -> Doc
ppType (TVar v)    = text $ tyvarName v
ppType TInt        = "Int"
ppType TBool       = "Bool"
ppType (TFun t s)  = ppParenType t <+> "->" <+> ppType s
ppType (TRecord r) = braces $ (hsep $ punctuate comma $ map ppEntry ls)
                              <> maybe empty ppRowVar mv
  where
    (ls, mv)       = toList r
    ppRowVar r     = space <> "|" <+> text (tyvarName r)
    ppEntry (l, t) = text l <+> "=" <+> ppType t
ppType _ = error "Unexpected type"

ppParenType :: Type -> Doc
ppParenType t =
  case t of
    TFun {} -> parens $ ppType t
    _       -> ppType t

instance Show Exp where
  showsPrec _ x = shows $ ppExp x

ppExp :: Exp -> Doc
ppExp (EVar name)     = text name
ppExp (EPrim prim)    = ppPrim prim
ppExp (ELet x b body) = "let" <+> text x <+> "=" <+>
                         ppExp b <+> "in" <//>
                         indent 2 (ppExp body)
ppExp (EApp e1 e2)    = ppExp e1 <+> ppParenExp e2
ppExp (EAbs n e)      = char '\\' <> text n <+> "->" <+> ppExp e

ppParenExp :: Exp -> Doc
ppParenExp t =
  case t of
    ELet {} -> parens $ ppExp t
    EApp {} -> parens $ ppExp t
    EAbs {} -> parens $ ppExp t
    _       -> ppExp t

instance Show Prim where
    showsPrec _ x = shows $ ppPrim x

ppPrim :: Prim -> Doc
ppPrim (Int i)            = integer i
ppPrim (Bool b)           = if b then "True" else "False"
ppPrim (RecordSelect l)   = "(_." <> text l <> ")"
ppPrim (RecordExtend l)   = "{"   <> text l <>  "=_|_}"
ppPrim (RecordRestrict l) = "(_-" <> text l <> ")"
ppPrim RecordEmpty        = "{}"

instance Show Scheme where
  showsPrec _ x = shows $ ppScheme x

ppScheme :: Scheme -> Doc
ppScheme (Scheme vars t) =
  "forall" <+> hcat (punctuate space $ map (text . tyvarName) vars) <> "."
           <+> parens (hcat $ punctuate comma $ concatMap ppConstraint vars) <+> "=>"
           <+> ppType t
  where
    ppConstraint :: TyVar -> [Doc]
    ppConstraint (TyVar n c) =
      case c of
        CNone -> []
        CRowLacks (S.toList -> ls)
          | null ls   -> []
          | otherwise -> [hcat (punctuate "\\" $ text n : map text ls)]
