import * as cdk from 'aws-cdk-lib';
import * as path from 'path';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as lambdaEventSources from 'aws-cdk-lib/aws-lambda-event-sources';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as vpclattice from 'aws-cdk-lib/aws-vpclattice';
import { Construct } from 'constructs';
import { GuardianObserve } from './guardian-observe';

export interface DivisionServiceStackProps extends cdk.StackProps {
  partition: string;
  division: string;
  department: string;
  repoUrl: string;
  /** VPC Lattice / Service Connect OTLP gateway, e.g. http://strata-otlp...:4318 */
  otlpEndpoint?: string;
  /** In-VPC Lattice OTLP endpoint for the Lambda (no internet egress). */
  otlpLambdaEndpoint?: string;
  /** Bearer token accepted by the OTLP gateway. */
  otlpToken?: string;
  /** Shared Lattice service network ARN; associates this stack's VPC. */
  otlpServiceNetworkArn?: string;
  /** Downstream app URL for the k8s -> AWS -> GCP trace direction. */
  downstreamUrl?: string;
}

/**
 * Departmental microservice CDK stack deployed directly in AWS:
 *   - DynamoDB Table (<partition>-items)
 *   - SQS Queue (<partition>-events)
 *   - Lambda Worker (<partition>-processor, X-Ray active tracing, SQS -> DynamoDB)
 *   - ECS Fargate Service + ALB (<partition>-service + OTel app/ADOT)
 *   - SSM Parameter (/strata-divisions/<partition>/config) for live drift detection
 *   - GuardianObserve construct (/guardian/onboarding/<StackName> + CW OTel sidecar)
 */
export class DivisionServiceStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: DivisionServiceStackProps) {
    super(scope, id, props);

    cdk.Tags.of(this).add('strata.io/division', props.division);
    cdk.Tags.of(this).add('strata.io/department', props.department);
    cdk.Tags.of(this).add('strata.io/partition', props.partition);

    // 1. Shared CloudWatch Log Group named so Doctor extracts guardian_partition automatically:
    //    guardian/<account>/<region>/<partition>/app
    const logGroup = new logs.LogGroup(this, 'ServiceLogs', {
      logGroupName: `guardian/${this.account}/${this.region}/${props.partition}/app`,
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // 2. DynamoDB Table for domain records
    const table = new dynamodb.Table(this, 'ItemsTable', {
      tableName: `${props.partition}-items`,
      partitionKey: { name: 'itemId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // 3. SQS Queue for asynchronous domain events
    const queue = new sqs.Queue(this, 'EventsQueue', {
      queueName: `${props.partition}-events`,
      visibilityTimeout: cdk.Duration.seconds(30),
      retentionPeriod: cdk.Duration.days(1),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // 4. VPC, SQS endpoint, Lambda worker, and VPC Lattice association.
    // The Lambda needs outbound OTLP egress; the demo uses one NAT gateway so
    // the Lambda can reach the public OTLP ALB without a PrivateLink endpoint.
    const vpc = new ec2.Vpc(this, 'Vpc', {
      availabilityZones: ['us-east-1a', 'us-east-1b'],
      natGateways: 1,
      subnetConfiguration: [
        { name: 'Public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'Private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });
    const lambdaSg = new ec2.SecurityGroup(this, 'LambdaSg', {
      vpc,
      description: 'Lambda to SQS/Lattice/OTLP',
      allowAllOutbound: true,
    });
    const sqsEndpoint = vpc.addInterfaceEndpoint('SqsEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.SQS,
      privateDnsEnabled: true,
    });
    sqsEndpoint.connections.allowDefaultPortFrom(lambdaSg);
    vpc.addGatewayEndpoint('DynamoDbEndpoint', {
      service: ec2.GatewayVpcEndpointAwsService.DYNAMODB,
    });

    if (props.otlpServiceNetworkArn) {
      const latticeSg = new ec2.SecurityGroup(this, 'LatticeAssociationSg', {
        vpc,
        description: 'VPC Lattice service network association',
        allowAllOutbound: true,
      });
      latticeSg.addIngressRule(
        ec2.Peer.ipv4(vpc.vpcCidrBlock),
        ec2.Port.tcp(4318),
        'VPC workloads to Lattice OTLP',
      );
      new vpclattice.CfnServiceNetworkVpcAssociation(this, 'OtlpLatticeAssociation', {
        serviceNetworkIdentifier: props.otlpServiceNetworkArn,
        vpcIdentifier: vpc.vpcId,
        securityGroupIds: [latticeSg.securityGroupId],
        privateDnsEnabled: true,
      });
    }

    const cluster = new ecs.Cluster(this, 'Cluster', {
      vpc,
      clusterName: `${props.partition}-cluster`,
    });

    const otlpEndpoint = String(props.otlpEndpoint || '').trim();
    const lambdaOtlpEndpoint = String(props.otlpLambdaEndpoint || otlpEndpoint).trim();
    const otlpHeaders = lambdaOtlpEndpoint && props.otlpToken
      ? `authorization=Bearer ${props.otlpToken}`
      : '';

    const processorFn = new NodejsFunction(this, 'EventProcessorFn', {
      functionName: `${props.partition}-processor`,
      runtime: lambda.Runtime.NODEJS_22_X,
      entry: path.join(__dirname, '..', 'lambda', 'index.js'),
      handler: 'handler',
      bundling: {
        // OTel's SDK relies on class identity; esbuild's minifier can rename
        // a class and break `instanceof`/constructor lookups at init time.
        minify: false,
        sourceMap: false,
        // Bundle the AWS SDK v3 DynamoDB client too. The X-Ray SDK's
        // captureAWSv3Client hooks the client's smithy middleware stack; pinning
        // the client in the bundle keeps it compatible with the bundled X-Ray
        // SDK instead of depending on whatever version the Lambda runtime ships.
      },
      timeout: cdk.Duration.seconds(15),
      memorySize: 128,
      tracing: lambda.Tracing.ACTIVE,
      logGroup,
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      securityGroups: [lambdaSg],
      environment: {
        TABLE_NAME: table.tableName,
        PARTITION_NAME: props.partition,
        DIVISION_NAME: props.division,
        DEPARTMENT_NAME: props.department,
        OTEL_SERVICE_NAME: `${props.partition}.app.processor`,
        OTEL_PROPAGATORS: 'tracecontext,baggage',
        OTEL_TRACES_SAMPLER: 'parentbased_always_on',
        OTEL_RESOURCE_ATTRIBUTES: [
          `service.namespace=${props.partition}`,
          `guardian.partition=${props.partition}`,
          'guardian.intent=aws',
          'guardian.asset=processor',
          'guardian.asset.type=Compute',
          'guardian.identity.kind=managed',
          `guardian.account=${this.account}`,
          `guardian.region=${this.region}`,
        ].join(','),
        ...(lambdaOtlpEndpoint
          ? {
              OTEL_EXPORTER_OTLP_ENDPOINT: lambdaOtlpEndpoint,
              OTEL_EXPORTER_OTLP_PROTOCOL: 'http/protobuf',
              ...(otlpHeaders ? { OTEL_EXPORTER_OTLP_HEADERS: otlpHeaders } : {}),
            }
          : {}),
      },
    });

    table.grantReadWriteData(processorFn);
    processorFn.addEventSource(new lambdaEventSources.SqsEventSource(queue, { batchSize: 5 }));

    // 5. ECS Fargate service + ALB
    const logDriver = ecs.LogDrivers.awsLogs({ streamPrefix: props.partition, logGroup });

    const taskDefinition = new ecs.FargateTaskDefinition(this, 'Task', {
      cpu: 512,
      memoryLimitMiB: 1024,
    });
    const appContainer = taskDefinition.addContainer('app', {
      image: ecs.ContainerImage.fromAsset(path.join(__dirname, '..', '..', 'app')),
      portMappings: [{ containerPort: 8080 }],
      environment: {
        PARTITION_NAME: props.partition,
        DIVISION_NAME: props.division,
        DEPARTMENT_NAME: props.department,
        QUEUE_URL: queue.queueUrl,
        TABLE_NAME: table.tableName,
        PORT: '8080',
        AWS_REGION: this.region,
        OTEL_SERVICE_NAME: `${props.partition}.app.service`,
        OTEL_RESOURCE_ATTRIBUTES: [
          `service.namespace=${props.partition}`,
          `guardian.partition=${props.partition}`,
          'guardian.intent=aws',
          'guardian.asset=service',
          'guardian.asset.type=Compute',
          'guardian.identity.kind=managed',
          `guardian.account=${this.account}`,
          `guardian.region=${this.region}`,
        ].join(','),
        OTEL_EXPORTER_OTLP_ENDPOINT: otlpEndpoint || 'http://localhost:4318',
        OTEL_EXPORTER_OTLP_PROTOCOL: 'http/protobuf',
        ...(otlpEndpoint && otlpHeaders ? { OTEL_EXPORTER_OTLP_HEADERS: otlpHeaders } : {}),
        OTEL_PROPAGATORS: 'tracecontext,baggage,xray',
        OTEL_TRACES_SAMPLER: 'parentbased_always_on',
        ...(props.downstreamUrl ? { TARGET_URL: props.downstreamUrl } : {}),
      },
      logging: logDriver,
    });

    // Local fallback: when no platform gateway is configured, keep the ADOT
    // sidecar and export to X-Ray. In the real deployment the app sends OTLP
    // straight to the platform gateway and this sidecar is omitted.
    if (!otlpEndpoint) {
      const collectorConfig = JSON.stringify({
        receivers: {
          otlp: {
            protocols: {
              grpc: { endpoint: '0.0.0.0:4317' },
              http: { endpoint: '0.0.0.0:4318' },
            },
          },
        },
        processors: { batch: {} },
        exporters: { awsxray: { region: this.region } },
        service: {
          pipelines: {
            traces: { receivers: ['otlp'], processors: ['batch'], exporters: ['awsxray'] },
          },
        },
      });
      const collector = taskDefinition.addContainer('otel-collector', {
        image: ecs.ContainerImage.fromRegistry('public.ecr.aws/aws-observability/aws-otel-collector:v0.50.0'),
        command: ['--config=env:AOT_CONFIG_CONTENT'],
        environment: {
          AOT_CONFIG_CONTENT: collectorConfig,
          AWS_REGION: this.region,
        },
        essential: false,
        logging: logDriver,
      });
      appContainer.addContainerDependencies({
        container: collector,
        condition: ecs.ContainerDependencyCondition.START,
      });
      taskDefinition.taskRole.addToPrincipalPolicy(new iam.PolicyStatement({
        actions: ['xray:PutTraceSegments', 'xray:PutTelemetryRecords'],
        resources: ['*'],
      }));
    }

    queue.grantSendMessages(taskDefinition.taskRole);
    table.grantReadWriteData(taskDefinition.taskRole);

    const securityGroup = new ec2.SecurityGroup(this, 'ServiceSg', { vpc });
    const service = new ecs.FargateService(this, 'Service', {
      cluster,
      serviceName: `${props.partition}-ecs`,
      taskDefinition,
      desiredCount: 1,
      minHealthyPercent: 100,
      maxHealthyPercent: 200,
      circuitBreaker: { rollback: true },
      assignPublicIp: true,
      securityGroups: [securityGroup],
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
    });

    const alb = new elbv2.ApplicationLoadBalancer(this, 'Alb', {
      vpc,
      internetFacing: true,
    });
    // ALB request tracing is always enabled: the load balancer generates or
    // propagates X-Amzn-Trace-Id without a load-balancer attribute. The
    // application continues the W3C/X-Ray context from that header.
    const listener = alb.addListener('Http', { port: 80, open: true });
    listener.addTargets('App', {
      port: 8080,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [service.loadBalancerTarget({ containerName: 'app', containerPort: 8080 })],
      healthCheck: { path: '/health', healthyHttpCodes: '200' },
    });
    securityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(8080), 'ALB to ECS app');

    // 6. SSM Parameter used to demonstrate out-of-band drift detection (Observed -> ObservedDrifted)
    const driftParam = new ssm.StringParameter(this, 'DriftParameter', {
      parameterName: `/strata-divisions/${props.partition}/config`,
      description: `Runtime configuration for ${props.partition} (${props.division})`,
      stringValue: `baseline-${props.partition}`,
    });

    // 7. GuardianObserve construct: tags stack, writes /guardian/onboarding/<StackName>,
    //    registers ALB HTTP health probe, and injects CloudWatch OTel agent sidecar.
    new GuardianObserve(this, 'Guardian', {
      partition: props.partition,
      intent: 'aws',
      repo: {
        url: props.repoUrl,
        branch: 'main',
        selector: this.stackName,
      },
      publish: { mode: 'store' },
      probes: [
        {
          name: 'alb-health',
          type: 'http',
          url: alb.loadBalancerDnsName,
          path: '/health',
          expectStatus: [200],
        },
      ],
      // The ADOT collector owns OTLP/traces here; the CloudWatch agent is not
      // needed and would conflict on the OTLP ports.
      telemetry: {
        enabled: false,
        logGroup: logGroup.logGroupName,
        source: 'doctor',
      },
      targets: [service],
    });

    new cdk.CfnOutput(this, 'AlbUrl', { value: `http://${alb.loadBalancerDnsName}` });
    new cdk.CfnOutput(this, 'QueueUrl', { value: queue.queueUrl });
    new cdk.CfnOutput(this, 'TableName', { value: table.tableName });
    new cdk.CfnOutput(this, 'LambdaName', { value: processorFn.functionName });
    new cdk.CfnOutput(this, 'LogGroupName', { value: logGroup.logGroupName });
    new cdk.CfnOutput(this, 'DriftParameterName', { value: driftParam.parameterName });
  }
}
