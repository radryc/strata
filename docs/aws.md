# Deploy Strata to AWS

The public [`aws`](https://github.com/radryc/aws) CDK project deploys MonoFS,
Guardian, and optionally Doctor/OTLP to ECS Fargate. It is independent of a
local kind cluster.

## 1. Clone and configure

```bash
git clone https://github.com/radryc/strata.git
cd strata
./scripts/clone.sh

# Build the CLI used by the onboarding examples.
mkdir -p bin
go build -o bin/guardianctl ../guardian/cmd/guardianctl
export PATH="$PWD/bin:$PATH"

cd ../aws
npm install
```

Choose an AWS profile and region:

```bash
export AWS_PROFILE=my-profile
export AWS_REGION=eu-west-1
aws sts get-caller-identity
```

## 2. Bootstrap CDK and the encryption key

```bash
npx cdk bootstrap "aws://$(aws sts get-caller-identity --query Account --output text)/$AWS_REGION"
```

Deploy the stack once so the secret exists:

```bash
./deploy.sh -y
```

Then set the MonoFS encryption key and restart the storage service:

```bash
aws secretsmanager put-secret-value \
  --secret-id strata/monofs/encryption-key \
  --secret-string "$(openssl rand -hex 32)" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

The CDK output includes the Guardian and MonoFS URLs, the MonoFS token secret,
and (when enabled) the Doctor URL and OTLP endpoint.

Cognito SSO is enabled by default in `cdk.json`. `./deploy.sh` uses
`STRATA_ADMIN_PASSWORD` when set; otherwise it generates a one-time password.
The demo users are `akadmin` (`admin@example.com`), `usera`, and `userb`.
See [access-and-login.md](access-and-login.md) for creating users, resetting
passwords, and Cognito CLI commands.

## 3. Deploy with the AWS pusher

```bash
./deploy.sh --with-pusher -y
```

The CDK project deploys Doctor and the OTLP gateway by default
(`deployObservability=true`). `--with-pusher` adds the AWS read API and pusher
used for observed stacks. Disable observability with
`-c deployObservability=false` if you do not need it.

Useful outputs:

```bash
aws cloudformation describe-stacks --stack-name StrataStack \
  --query 'Stacks[0].Outputs' --output table
aws cloudformation describe-stacks --stack-name AwsPusherStack \
  --query 'Stacks[0].Outputs' --output table
```

The important output names are `AppUrl`, `MonofsUrl`,
`MonofsTokenSecretArn`, `DoctorUrl`, `AwsReadApiUrl`,
`AwsReadTokenSecretArn`, and `PusherName`.

## 4. Register the AWS pusher

The CDK stack creates the pusher service. Register it with Guardian using the
outputs from the stack (the exact command is printed by `./deploy.sh`):

```bash
guardianctl --guardian-url "$GUARDIAN_URL" pusher add \
  --name "aws-$ACCOUNT" \
  --account "$ACCOUNT" \
  --region "$AWS_REGION" \
  --url "$AWS_READ_API_URL" \
  --token "$AWS_READ_TOKEN"
```

## 5. Onboard an application on AWS

An application repository can own an AWS partition just like the Kubernetes
example. The partition lives in the same repository:

```text
my-app/
├── .guardian/config.yaml
└── guardian/partitions/my-app/
    ├── config.yaml
    └── intents/app.yaml
```

For a CDK application, synthesize the assembly and reference it from the
intent:

```yaml
spec:
  implementation: cdk
  targetPusher: aws-123456789012
  target:
    account: "123456789012"
    region: eu-west-1
  assets:
    - type: CDKStack
      name: my-app-stack
      payload:
        aws: /partitions/my-app/payloads/aws
      properties:
        stackName: MyAppStack
```

Then push the partition:

```bash
cd my-app
npx cdk synth --output cdk.out
mkdir -p guardian/partitions/my-app/payloads
cp -R cdk.out guardian/partitions/my-app/payloads/aws

guardianctl --guardian-url "$GUARDIAN_URL" repo add \
  --name my-app --pusher "aws-$ACCOUNT" --partition my-app \
  --source "$PWD" --account "$ACCOUNT" --region "$AWS_REGION"
guardianctl --guardian-url "$GUARDIAN_URL" repo import \
  --name my-app --source "$PWD"
```

The AWS pusher assumes the configured execution role and deploys the stack.
For the native AWS asset types (Compute, ObjectStore, LoadBalancer, …), use
`implementation: native`; for full control over the CloudFormation template,
use `implementation: cdk` and commit only the synthesized assembly reference.

## 6. Teardown

```bash
cd ../aws
npx cdk destroy AwsPusherStack ObservabilityStack StrataStack
```

Delete the MonoFS S3/EFS resources only after you have exported any data you
need. The versioned S3 bucket is retained by CloudFormation by default; empty it
explicitly if you want a full teardown. See the `aws` repository README for the
full stack matrix and toggles.
