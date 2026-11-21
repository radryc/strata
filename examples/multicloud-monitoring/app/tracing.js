'use strict';

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { AWSXRayIdGenerator } = require('@opentelemetry/id-generator-aws-xray');
const { AWSXRayPropagator } = require('@opentelemetry/propagator-aws-xray');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { BatchSpanProcessor } = require('@opentelemetry/sdk-trace');
const {
  CompositePropagator,
  W3CTraceContextPropagator,
  W3CBaggagePropagator,
} = require('@opentelemetry/core');

function parseHeaders(raw) {
  const headers = {};
  for (const entry of String(raw || '').split(',')) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    headers[trimmed.slice(0, separator).trim()] = trimmed.slice(separator + 1).trim();
  }
  return headers;
}

function tracesEndpoint(raw) {
  const value = String(raw || 'http://localhost:4318').replace(/\/+$/, '');
  return value.endsWith('/v1/traces') ? value : `${value}/v1/traces`;
}

function resourceAttributes() {
  const attrs = {
    'service.name': process.env.OTEL_SERVICE_NAME || 'strata-demo-app',
  };
  for (const entry of (process.env.OTEL_RESOURCE_ATTRIBUTES || '').split(',')) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    attrs[trimmed.slice(0, separator)] = trimmed.slice(separator + 1);
  }
  const partition = process.env.PARTITION_NAME || process.env.GUARDIAN_PARTITION || '';
  if (partition) {
    // Doctor can canonicalize a trace/log partition from either the dotted
    // OTel resource form or the underscore query/label form.
    attrs['guardian.partition'] = attrs['guardian.partition'] || partition;
    attrs.guardian_partition = attrs.guardian_partition || partition;
  }
  return attrs;
}

// Cloud Trace exports span attributes (not arbitrary resource attributes) as
// labels. Copy the identity resource attributes onto every span so Doctor can
// enforce partition access on federated GCP traces.
class IdentitySpanProcessor {
  constructor(attrs) {
    this.attrs = attrs;
    this.keys = [
      'service.name',
      'service.namespace',
      'guardian.partition',
      'guardian_partition',
      'guardian.intent',
      'guardian.asset',
      'guardian.asset.type',
      'guardian.identity.kind',
    ];
  }

  onStart(span) {
    for (const key of this.keys) {
      if (this.attrs[key]) {
        span.setAttribute(key, this.attrs[key]);
      }
    }
  }

  onEnd() {}
  shutdown() {
    return Promise.resolve();
  }
  forceFlush() {
    return Promise.resolve();
  }
}

// GCP deployments export traces through Cloud Trace (Application Default
// Credentials from the Cloud Run service account). AWS/k8s keep the OTLP path.
const telemetryBackend = String(process.env.TELEMETRY_BACKEND || 'otlp').toLowerCase();
const isGCP = telemetryBackend === 'gcp';

let traceExporter;
let idGenerator;
let textMapPropagator;
if (isGCP) {
  const { TraceExporter: CloudTraceExporter } = require('@google-cloud/opentelemetry-cloud-trace-exporter');
  traceExporter = new CloudTraceExporter();
  // Cloud Trace uses W3C trace context; no AWS X-Ray generator/propagator.
  textMapPropagator = new CompositePropagator({
    propagators: [new W3CTraceContextPropagator(), new W3CBaggagePropagator()],
  });
} else {
  traceExporter = new OTLPTraceExporter({
    url: tracesEndpoint(process.env.OTEL_EXPORTER_OTLP_ENDPOINT),
    headers: parseHeaders(process.env.OTEL_EXPORTER_OTLP_HEADERS),
  });
  idGenerator = new AWSXRayIdGenerator();
  textMapPropagator = new CompositePropagator({
    propagators: [
      new W3CTraceContextPropagator(),
      new W3CBaggagePropagator(),
      new AWSXRayPropagator(),
    ],
  });
}

const sdkConfig = {
  resource: resourceFromAttributes(resourceAttributes()),
  traceExporter,
  instrumentations: [getNodeAutoInstrumentations()],
  textMapPropagator,
};
if (idGenerator) sdkConfig.idGenerator = idGenerator;
// GCP Cloud Trace only persists span attributes as queryable labels. Keep the
// batch exporter and add the identity processor, because providing
// spanProcessors replaces the SDK's default batch processor.
if (isGCP) {
  sdkConfig.spanProcessors = [
    new BatchSpanProcessor({ exporter: traceExporter }),
    new IdentitySpanProcessor(resourceAttributes()),
  ];
  delete sdkConfig.traceExporter;
}
const sdk = new NodeSDK(sdkConfig);

sdk.start();
process.on('SIGTERM', () => {
  sdk.shutdown().finally(() => process.exit(0));
});
