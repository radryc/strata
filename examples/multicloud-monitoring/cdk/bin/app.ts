import * as cdk from 'aws-cdk-lib';
import { DivisionServiceStack } from '../lib/service-stack';

const app = new cdk.App();

const region =
  process.env.AWS_REGION ||
  process.env.CDK_DEFAULT_REGION ||
  'us-east-1';

const accountA = process.env.AWS_ACCOUNT_A || process.env.CDK_DEFAULT_ACCOUNT || '';
const accountB = process.env.AWS_ACCOUNT_B || process.env.CDK_DEFAULT_ACCOUNT || accountA;

const otlpEndpoint = process.env.STRATA_OTLP_ENDPOINT || '';
const otlpLambdaEndpoint = process.env.STRATA_OTLP_LAMBDA_ENDPOINT || '';
const otlpToken = process.env.STRATA_OTLP_TOKEN || '';
const otlpServiceNetworkArn = process.env.STRATA_OTLP_LATTICE_SERVICE_NETWORK_ARN || '';

function makeStack(args: {
  stackName: string;
  account: string;
  partition: string;
  division: string;
  department: string;
  repoUrl: string;
  downstreamUrl: string;
}) {
  new DivisionServiceStack(app, args.stackName, {
    env: args.account ? { account: args.account, region } : { region },
    partition: args.partition,
    division: args.division,
    department: args.department,
    repoUrl: args.repoUrl,
    downstreamUrl: args.downstreamUrl,
    otlpEndpoint,
    otlpLambdaEndpoint,
    otlpToken,
    otlpServiceNetworkArn,
    description: `Strata multicloud example: ${args.partition} (${args.division}) — ECS + SQS + Lambda + DynamoDB + ALB + GuardianObserve`,
  });
}

// One CDK assembly carries both division stacks. The Guardian repo binding
// selects each stack by name (DivASharedStack / DivBSharedStack).
makeStack({
  stackName: 'DivASharedStack',
  account: accountA,
  partition: 'diva-shared',
  division: 'DivisionA',
  department: 'DepartmentA',
  repoUrl: process.env.GUARDIAN_REPO_A || '',
  downstreamUrl: process.env.AWS_DOWNSTREAM_URL_A || '',
});

makeStack({
  stackName: 'DivBSharedStack',
  account: accountB,
  partition: 'divb-shared',
  division: 'DivisionB',
  department: 'DepartmentB',
  repoUrl: process.env.GUARDIAN_REPO_B || '',
  downstreamUrl: process.env.AWS_DOWNSTREAM_URL_B || '',
});

app.synth();
