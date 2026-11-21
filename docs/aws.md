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

Deploy the stack once; it creates `strata/monofs/encryption-key` with a
generated 64-hex-character key:

```bash
./deploy.sh -y
```

To use a key you control, write it before MonoFS stores any data (replacing the
key later makes existing data unreadable), then restart the storage service:

```bash
aws secretsmanager put-secret-value \
  --secret-id strata/monofs/encryption-key \
  --secret-string "$(openssl rand -hex 32)" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

`StrataStack` outputs the Guardian and MonoFS URLs, the MonoFS token secret, and
(when SSO and observability are enabled) the Doctor URL. `ObservabilityStack`
outputs the OTLP endpoint.

Cognito SSO is enabled by default in `cdk.json`. `./deploy.sh` uses
`STRATA_ADMIN_PASSWORD` when set; otherwise it generates a one-time password.
The demo users are `akadmin` (`admin@example.com`), `usera`, and `userb`.
See [access-and-login.md](access-and-login.md) for creating users, resetting
passwords, and Cognito CLI commands.

## 3. Deploy with the AWS pusher

```bash
./deploy.sh --with-pusher -y
```

`deploy.sh` deploys `StrataStack`, plus `AwsPusherStack` with `--with-pusher`
and `DemoStack` with `--with-demo`. Doctor and the OTLP gateway live in the
separate `ObservabilityStack` (the CDK app enables it with
`deployObservability=true`); deploy it explicitly with `npx cdk deploy` when you
need AWS-side observability, or disable it with `-c deployObservability=false`
if you do not.

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
`PusherName`, `AwsReadApiUrl`, and `AwsReadTokenSecretArn` outputs from the
stack:

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
├── cdk/                       # CDK application (for implementation: cdk)
└── guardian/partitions/my-app/
    ├── config.yaml
    ├── intents/app.yaml
    └── payloads/stack.yaml
```

For a CDK application, synthesize the assembly and describe it in a payload
manifest that the intent references:

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
        aws: /partitions/my-app/payloads/stack.yaml
      properties:
        context:
          appName: my-app
```

`guardian/partitions/my-app/payloads/stack.yaml` points at the synthesized
assembly:

```yaml
sourceType: cdk-ts
prebuiltAssemblyDir: /partitions/my-app/payloads/aws
stackName: MyAppStack
stackID: MyAppStack
```

Then push the partition:

```bash
cd my-app
(cd cdk && npx cdk synth --output ../guardian/partitions/my-app/payloads/aws)

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
npx cdk destroy AwsPusherStack DemoStack ObservabilityStack StrataStack
```

Pass only the stacks you deployed. Export any data you need first: the versioned
S3 bucket and the EFS filesystem use `removalPolicy: DESTROY`. See the `aws`
repository README for the full stack matrix and toggles.
