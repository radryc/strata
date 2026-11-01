# Example AWS application repository

This is the AWS variant of the onboarding example. The application is a small
CDK stack; Guardian deploys it through the AWS pusher.

```text
aws-app/
├── .guardian/config.yaml
├── cdk/                                      # CDK application
│   ├── bin/app.ts
│   ├── cdk.json
│   └── lib/stack.ts
└── guardian/partitions/aws-app/              # dedicated partition
    ├── config.yaml
    ├── intents/app.yaml
    └── payloads/stack.yaml
```

## Prerequisites

- AWS credentials with permission to deploy the stack
- Node.js 20+
- `guardianctl` and a registered AWS pusher (`aws-<account>`)

## 1. Update the account and region

Edit `.guardian/config.yaml` and
`guardian/partitions/aws-app/intents/app.yaml` and replace:

- `123456789012` with your AWS account ID;
- `eu-west-1` with your region;
- `aws-123456789012` with the pusher name registered in Guardian.

## 2. Synthesize the assembly

```bash
cd cdk
npm ci
npx cdk synth --output ../guardian/partitions/aws-app/payloads/aws
```

Commit the generated `payloads/aws` assembly if your CI pushes the repository
as-is, or generate it in CI before `repo import`.

## 3. Register and import

```bash
guardianctl --guardian-url "$GUARDIAN_URL" repo add \
  --name aws-app --pusher "aws-$ACCOUNT" --partition aws-app \
  --source "$PWD" --account "$ACCOUNT" --region "$AWS_REGION"
guardianctl --guardian-url "$GUARDIAN_URL" repo import \
  --name aws-app --source "$PWD"
```

Guardian asks the AWS pusher to deploy `OnboardingAppStack`. The pusher assumes
the configured execution role; no AWS credentials live in this repository.

See [docs/aws.md](../../docs/aws.md) and
[docs/onboarding-application.md](../../docs/onboarding-application.md).
