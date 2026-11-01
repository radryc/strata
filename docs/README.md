# Strata documentation

Start here:

| Guide | Use it when |
|---|---|
| [local-kind.md](local-kind.md) | You want a working stack on your laptop in one command |
| [kubernetes.md](kubernetes.md) | You have a Kubernetes cluster and want to deploy Strata |
| [access-and-login.md](access-and-login.md) | You need to log in, create users, or set passwords |
| [aws.md](aws.md) | You want the control plane on AWS ECS/Fargate |
| [onboarding-application.md](onboarding-application.md) | You want to deploy an app from its own repository |
| [bootstrap-partition.md](bootstrap-partition.md) | You want the prepared, key-free partition template |
| [production-gap-plan.md](production-gap-plan.md) | You want the cross-service production readiness plan |

The quickest path:

```bash
./scripts/clone.sh
./scripts/dev-kind-up.sh
```
