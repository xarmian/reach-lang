module Reach.Linearize (linearize) where

import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq
import Reach.AST
import Reach.Type
import Reach.Util

type FluidEnv = M.Map FluidVar (SrcLoc, DLArg)

type LLRets = M.Map Int DLVar

lin_com :: SLLimits -> String -> (SrcLoc -> FluidEnv -> LLRets -> DLStmts -> a) -> (LLCommon a -> a) -> FluidEnv -> LLRets -> DLStmt -> DLStmts -> a
lin_com lims who back mkk fve rets s ks =
  case s of
    DLS_FluidSet at fv da -> back at fve' rets ks
      where
        fve' = M.insert fv (at, da) fve
    DLS_FluidRef at dv fv ->
      mkk $ LL_Let at (Just dv) (DLE_Arg at' da) $ back at fve rets ks
      where
        (at', da) =
          case M.lookup fv fve of
            Nothing -> impossible $ "fluid ref unbound: " <> show fv
            Just x -> x
    DLS_Let at mdv de -> mkk $ LL_Let at mdv de $ back at fve rets ks
    DLS_ArrayMap at ans x a f r ->
      mkk $ LL_ArrayMap at ans x a f' r $ back at fve rets ks
      where
        f' = lin_local lims at fve f
    DLS_ArrayReduce at ans x z b a f r ->
      mkk $ LL_ArrayReduce at ans x z b a f' r $ back at fve rets ks
      where
        f' = lin_local lims at fve f
    DLS_If at ca _ ts fs
      | isLocal s ->
        mkk $ LL_LocalIf at ca t' f' $ back at fve rets ks
      where
        t' = lin_local_rets lims at fve rets ts
        f' = lin_local_rets lims at fve rets fs
    DLS_Switch at dv _ cm
      | isLocal s ->
        mkk $ LL_LocalSwitch at dv cm' $ back at fve rets ks
      where
        cm' = M.map cm1 cm
        cm1 (dv', l) = (dv', lin_local_rets lims at fve rets l)
    DLS_Return at ret sv ->
      case M.lookup ret rets of
        Nothing -> back at fve rets ks
        Just dv -> mkk $ LL_Set at dv da $ back at fve rets ks
          where
            (_, da) = typeOf lims at sv
    DLS_Prompt at (Left _) ss -> back at fve rets (ss <> ks)
    DLS_Prompt at (Right dv@(DLVar _ _ _ ret)) ss ->
      mkk $ LL_Var at dv $ back at fve rets' (ss <> ks)
      where
        rets' = M.insert ret dv rets
    DLS_If {} ->
      impossible $ who ++ " cannot non-local if"
    DLS_Switch {} ->
      impossible $ who ++ " cannot non-local switch"
    DLS_Stop {} ->
      impossible $ who ++ " cannot stop"
    DLS_Only {} ->
      impossible $ who ++ " cannot only"
    DLS_ToConsensus {} ->
      impossible $ who ++ " cannot consensus"
    DLS_FromConsensus {} ->
      impossible $ who ++ " cannot fromconsensus"
    DLS_While {} ->
      impossible $ who ++ " cannot while"
    DLS_Continue {} ->
      impossible $ who ++ " cannot while"

lin_local_rets :: SLLimits -> SrcLoc -> FluidEnv -> LLRets -> DLStmts -> LLLocal
lin_local_rets _ at _ _ Seq.Empty =
  LLL_Com $ LL_Return at
lin_local_rets lims _ fve rets (s Seq.:<| ks) =
  lin_com lims "local" (lin_local_rets lims) LLL_Com fve rets s ks

lin_local :: SLLimits -> SrcLoc -> FluidEnv -> DLStmts -> LLLocal
lin_local lims at fve ks = lin_local_rets lims at fve mempty ks

lin_con :: SLLimits -> (FluidEnv -> DLStmts -> LLStep) -> SrcLoc -> FluidEnv -> LLRets -> DLStmts -> LLConsensus
lin_con _ _ at _ _ Seq.Empty =
  LLC_Com $ LL_Return at
lin_con lims back at_top fve rets (s Seq.:<| ks) =
  case s of
    DLS_If at ca _ ts fs
      | not (isLocal s) ->
        LLC_If at ca t' f'
      where
        t' = lin_con lims back at fve rets (ts <> ks)
        f' = lin_con lims back at fve rets (fs <> ks)
    DLS_Switch at dv _ cm
      | not (isLocal s) ->
        LLC_Switch at dv cm'
      where
        cm' = M.map cm1 cm
        cm1 (dv', c) = (dv', lin_con lims back at fve rets (c <> ks))
    DLS_FromConsensus at cons ->
      LLC_FromConsensus at at_top $ back fve (cons <> ks)
    DLS_While at asn inv_b cond_b body ->
      LLC_While at asn (block inv_b) (block cond_b) body' $
        lin_con lims back at fve rets ks
      where
        body' = lin_con lims back at fve rets body
        --- Note: The invariant and condition can't return
        block (DLBlock ba fs ss a) =
          LLBlock ba fs (lin_local lims ba fve ss) a
    DLS_Continue at update ->
      case ks of
        Seq.Empty ->
          LLC_Continue at update
        _ ->
          impossible $ "consensus cannot continue w/ non-empty k"
    _ ->
      lin_com lims "consensus" (lin_con lims back) LLC_Com fve rets s ks

lin_step :: SLLimits -> SrcLoc -> FluidEnv -> LLRets -> DLStmts -> LLStep
lin_step _ at _ _ Seq.Empty =
  LLS_Stop at
lin_step lims _ fve rets (s Seq.:<| ks) =
  case s of
    DLS_If {}
      | not (isLocal s) ->
        impossible $ "step cannot unlocal if, must occur in consensus"
    DLS_Switch {}
      | not (isLocal s) ->
        impossible $ "step cannot unlocal switch, must occur in consensus"
    DLS_Stop at ->
      LLS_Stop at
    DLS_Only at who ss ->
      LLS_Only at who ls $ lin_step lims at fve rets ks
      where
        ls = lin_local lims at fve ss
    DLS_ToConsensus at who fs as ms amt amtv mtime cons ->
      LLS_ToConsensus at who fs as ms amt amtv mtime' cons'
      where
        cons' = lin_con lims back at fve mempty (cons <> ks)
        back fve' = lin_step lims at fve' rets
        mtime' = do
          (delay_da, time_ss) <- mtime
          return $ (delay_da, lin_step lims at fve rets (time_ss <> ks))
    _ ->
      lin_com lims "step" (lin_step lims) LLS_Com fve rets s ks

linearize :: DLProg -> LLProg
linearize (DLProg at (DLOpts {..}) sps ss) =
  LLProg at opts' sps $ lin_step dlo_lims at mempty mempty ss
  where
    opts' = LLOpts {..}
    llo_deployMode = dlo_deployMode
    llo_verifyOverflow = dlo_verifyOverflow
