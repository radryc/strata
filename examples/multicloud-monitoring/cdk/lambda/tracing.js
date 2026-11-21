'use strict';

const { context, propagation, trace } = require('@opentelemetry/api');
const { AsyncLocalStorageContextManager } = require('@opentelemetry/context-async-hooks');
const {
  CompositePropagator,
  W3CTraceContextPropagator,
  W3CBaggagePropagator,
} = require('@opentelemetry/core');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { registerInstrumentations } = require('@opentelemetry/instrumentation');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { AWSXRayIdGenerator } = require('@opentelemetry/id-generator-aws-xray');
const { AWSXRayPropagator } = require('@opentelemetry/propagator-aws-xray');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { TracerProvider, SimpleSpanProcessor } = require('@opentelemetry/sdk-trace');

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
    'service.name': process.env.OTEL_SERVICE_NAME || 'strata-demo-processor',
  };
  for (const entry of (process.env.OTEL_RESOURCE_ATTRIBUTES || '').split(',')) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    attrs[trimmed.slice(0, separator)] = trimmed.slice(separator + 1);
  }
  return attrs;
}

const otlpUrl = tracesEndpoint(process.env.OTEL_EXPORTER_OTLP_ENDPOINT);
const otlpHeaders = parseHeaders(process.env.OTEL_EXPORTER_OTLP_HEADERS);
const exporter = new OTLPTraceExporter({
  url: otlpUrl,
  headers: otlpHeaders,
});

const provider = new TracerProvider({
  resource: resourceFromAttributes(resourceAttributes()),
  idGenerator: new AWSXRayIdGenerator(),
  spanProcessors: [new SimpleSpanProcessor({ exporter })],
});
trace.setGlobalTracerProvider(provider);

const contextManager = new AsyncLocalStorageContextManager();
contextManager.enable();
context.setGlobalContextManager(contextManager);

propagation.setGlobalPropagator(
  new CompositePropagator({
    propagators: [
      new W3CTraceContextPropagator(),
      new W3CBaggagePropagator(),
      new AWSXRayPropagator(),
    ],
  }),
);

registerInstrumentations({
  tracerProvider: provider,
  instrumentations: [
    getNodeAutoInstrumentations({
      // The handler owns the Lambda span and extracts the SQS traceparent.
      // HTTP is disabled so the OTLP exporter does not add its own span.
      '@opentelemetry/instrumentation-aws-lambda': { enabled: false },
      '@opentelemetry/instrumentation-http': { enabled: false },
    }),
  ],
});

module.exports = {
  flush: () => exporter.forceFlush(),
  tracer: provider.getTracer('strata-demo-processor'),
};
