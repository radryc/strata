#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { OnboardingAppStack } from "../lib/stack";

const app = new cdk.App();
const appName = String(app.node.tryGetContext("appName") ?? "onboarding-app");
const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION || process.env.AWS_REGION || "us-east-1";

new OnboardingAppStack(app, "OnboardingAppStack", {
  env: account ? { account, region } : undefined,
  appName,
  description: "Example application stack managed by Guardian",
});
