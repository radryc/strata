# Strata documentation

Start here:

| Guide | Use it when |
|---|---|
| [architecture.md](architecture.md) | You want the repository layout, platform topology, and bootstrap flow |
| [local-kind.md](local-kind.md) | You want a working stack on your laptop in one command |
| [kubernetes.md](kubernetes.md) | You have a Kubernetes cluster and want to deploy Strata |
| [access-and-login.md](access-and-login.md) | You need to log in, create users, or set passwords |
| [aws.md](aws.md) | You want the control plane on AWS ECS/Fargate |
| [onboarding-application.md](onboarding-application.md) | You want to deploy an app from its own repository |
| [bootstrap-partition.md](bootstrap-partition.md) | You want the prepared, key-free partition template |

The quickest path:

```bash
./scripts/clone.sh
./scripts/dev-kind-up.sh
```
