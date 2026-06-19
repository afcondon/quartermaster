-- | The host-capability pre-flight model (`quartermaster verify`). Pure: derive
-- | the per-service capability REQUIREMENTS a deployment places on a host, and —
-- | given the effectful PROBE outcomes the CLI edge gathers — decide the per-
-- | service VERDICT (ready, or a list of typed findings). This is the
-- | host-readiness half of the Bosun⇄Quartermaster seam: Bosun consumes "host
-- | ready"; this computes it. Rides backend-go like Bosun's pure core.
module Quartermaster.Verify
  ( Requirement
  , requirementsOf
  , ProbeOutcome
  , Finding(..)
  , Verdict
  , verdictOf
  , ready
  ) where

import Prelude

import Bosun.Atoms (AbsPath, Host)
import Bosun.Executor as Executor
import Bosun.Service (ServiceInstance)
import Data.Array as A
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Quartermaster.Runtime (ProbeSpec(..), Runtime, probeSpec, runtimeOfExecutor)

-- | What one declared service needs of its host: the runtime to launch it, and
-- | (for a `Process`) the working directory that must exist. Keyed by the
-- | service's `localName` and tagged with its `host`, so the report reads per
-- | host. One per ingested facet (a 2-facet service yields 2 requirements —
-- | each host runs one; reconcile-dedup is a later refinement).
type Requirement =
  { service :: String
  , host :: Maybe Host
  , runtime :: Runtime
  , cwd :: Maybe AbsPath
  }

-- | Derive the requirements from ingested instances (compose ∪ registry). Pure —
-- | no probing here; just "what would each host need."
-- |
-- | Sorted by (host, service): the ingested order follows `Foreign.Object`
-- | iteration, which is insertion-order under node but unordered under Go
-- | (a backend-go build over a Go map). A defined total order makes the report
-- | deterministic across both runtimes — the same reason Bosun sorts its drift
-- | report by id — and reads better, grouped per host and alphabetical within.
requirementsOf :: Array ServiceInstance -> Array Requirement
requirementsOf = A.sortWith (\r -> Tuple r.host r.service) <<< map req
  where
  req si =
    { service: si.localName
    , host: si.host
    , runtime: runtimeOfExecutor si.executor
    , cwd: cwdOf si.executor
    }
  cwdOf = case _ of
    Executor.Process pr -> Just pr.cwd
    _ -> Nothing

-- | What the effectful probe edge (`Quartermaster.CLI.Probe`) reports back per
-- | requirement: did the runtime probe pass, an optional version string, and
-- | whether the launch cwd exists (`true` when there is no cwd to check).
type ProbeOutcome =
  { requirement :: Requirement
  , present :: Boolean
  , version :: Maybe String
  , cwdOk :: Boolean
  }

-- | A typed reason a host is NOT ready for a service. Never a bare boolean —
-- | each finding names what to provision (the seam points Bosun at exactly this).
data Finding
  = RuntimeMissing Runtime
  | CwdMissing AbsPath
  | Unclassified String   -- a launch Quartermaster can't classify (a `NoProbe` runtime)

derive instance Eq Finding

-- | The per-service verdict. Empty `findings` ⇒ the host can launch it.
type Verdict = { requirement :: Requirement, findings :: Array Finding }

-- | Turn a probe outcome into a verdict. A `NoProbe` runtime is reported as
-- | `Unclassified` (we couldn't check), NOT silently passed; a present runtime
-- | with a missing cwd still fails.
verdictOf :: ProbeOutcome -> Verdict
verdictOf o =
  { requirement: o.requirement
  , findings: A.catMaybes [ runtimeFinding, cwdFinding ]
  }
  where
  runtimeFinding = case probeSpec o.requirement.runtime of
    NoProbe note -> Just (Unclassified note)
    _ -> if o.present then Nothing else Just (RuntimeMissing o.requirement.runtime)
  cwdFinding = case o.requirement.cwd of
    Just p | not o.cwdOk -> Just (CwdMissing p)
    _ -> Nothing

ready :: Verdict -> Boolean
ready v = A.null v.findings
