import * as cdk from "aws-cdk-lib";
import * as s3 from "aws-cdk-lib/aws-s3";
import { Construct } from "constructs";

export interface OnboardingAppStackProps extends cdk.StackProps {
  appName: string;
}

export class OnboardingAppStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OnboardingAppStackProps) {
    super(scope, id, props);

    new s3.Bucket(this, "Assets", {
      bucketName: `${props.appName}-${this.account}-${this.region}`,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });
  }
}
