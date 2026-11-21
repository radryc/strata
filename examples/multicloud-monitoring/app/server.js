'use strict';

// One example app for all three providers:
//   - AWS ECS: receives ALB traffic, writes SQS events (Lambda -> DynamoDB)
//   - GCP Cloud Run: exports to Cloud Trace / Cloud Logging
//   - Kubernetes: entry point for both cross-provider trace directions
//
// Routes:
//   GET /                  native work (AWS: SQS event)
//   GET /trace             native work, returns the local trace ID
//   GET /trace/through     native work + one downstream hop to TARGET_URL/trace
//   GET /trace/gcp-aws     k8s -> GCP /trace/through -> AWS /trace
//   GET /trace/aws-gcp     k8s -> AWS /trace/through -> GCP /trace
//
// Forwarding a fixed "/trace" path (not "/trace/through") prevents cycles.

const http = require('http');
const https = require('https');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const { context, trace } = require('@opentelemetry/api');

const port = Number(process.env.PORT || 8080);
const queueUrl = process.env.QUEUE_URL || '';
const sqs = new SQSClient({ region: process.env.AWS_REGION });
const partition = process.env.PARTITION_NAME || process.env.GUARDIAN_PARTITION || 'unknown';
const targetURL = String(process.env.TARGET_URL || '').trim();
const awsTargetURL = String(process.env.AWS_TARGET_URL || '').trim();

function traceID() {
  return trace.getSpan(context.active())?.spanContext().traceId || '';
}

function traceHeaders() {
  const span = trace.getSpan(context.active());
  if (!span) {
    return {};
  }
  const sc = span.spanContext();
  const sampled = (sc.traceFlags & 1) === 1 ? '01' : '00';
  const xrayRoot = `1-${sc.traceId.slice(0, 8)}-${sc.traceId.slice(8)}`;
  return {
    traceparent: `00-${sc.traceId}-${sc.spanId}-${sampled}`,
    'X-Amzn-Trace-Id': `Root=${xrayRoot};Parent=${sc.spanId};Sampled=${sampled === '01' ? '1' : '0'}`,
  };
}

function joinURL(base, suffix) {
  const url = new URL(base);
  url.pathname = `${url.pathname.replace(/\/+$/, '')}${suffix}`;
  return url;
}

function callURL(base, suffix) {
  return new Promise((resolve, reject) => {
    if (!base) {
      reject(new Error('target URL is not configured'));
      return;
    }
    const url = joinURL(base, suffix);
    const client = url.protocol === 'https:' ? https : http;
    const req = client.get(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (url.protocol === 'https:' ? 443 : 80),
        path: `${url.pathname}${url.search}`,
        method: 'GET',
        timeout: 15_000,
      },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          body += chunk;
        });
        res.on('end', () => {
          resolve({ status: res.statusCode || 0, body });
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error('target request timed out')));
    req.on('error', reject);
  });
}

async function nativeWork() {
  const request = {
    partition,
    division: process.env.DIVISION_NAME || 'unknown',
    department: process.env.DEPARTMENT_NAME || 'unknown',
    action: 'order_created',
    receivedAt: new Date().toISOString(),
  };
  if (queueUrl) {
    const headers = traceHeaders();
    await sqs.send(new SendMessageCommand({
      QueueUrl: queueUrl,
      MessageBody: JSON.stringify(request),
      MessageSystemAttributes: headers['X-Amzn-Trace-Id']
        ? { AWSTraceHeader: { DataType: 'String', StringValue: headers['X-Amzn-Trace-Id'] } }
        : undefined,
      MessageAttributes: headers.traceparent
        ? { traceparent: { DataType: 'String', StringValue: headers.traceparent } }
        : undefined,
    }));
  }
  return request;
}

function sendJSON(res, status, payload) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(payload));
}

const server = http.createServer(async (req, res) => {
  const path = (req.url || '/').split('?')[0];
  console.log(JSON.stringify({
    level: 'INFO',
    event: 'request',
    path,
    partition,
    guardian_partition: partition,
    service: process.env.OTEL_SERVICE_NAME || 'strata-demo-app',
    traceId: traceID(),
  }));

  if (path === '/health' || path === '/ready') {
    sendJSON(res, 200, { status: 'ok' });
    return;
  }

  try {
    if (path === '/' || path === '/trace') {
      const request = await nativeWork();
      sendJSON(res, 200, { status: 'ok', traceId: traceID(), request });
      return;
    }

    if (path === '/trace/through') {
      const request = await nativeWork();
      let downstream = null;
      if (targetURL) {
        const result = await callURL(targetURL, '/trace');
        downstream = { status: result.status, body: result.body.slice(0, 2000) };
      }
      sendJSON(res, 200, { status: 'ok', traceId: traceID(), request, downstream });
      return;
    }

    if (path === '/trace/gcp-aws') {
      const result = await callURL(targetURL, '/trace/through');
      sendJSON(res, 200, {
        status: 'ok',
        traceId: traceID(),
        route: 'k8s -> gcp -> aws',
        downstream: { status: result.status, body: result.body.slice(0, 4000) },
      });
      return;
    }

    if (path === '/trace/aws-gcp') {
      const result = await callURL(awsTargetURL, '/trace/through');
      sendJSON(res, 200, {
        status: 'ok',
        traceId: traceID(),
        route: 'k8s -> aws -> gcp',
        downstream: { status: result.status, body: result.body.slice(0, 4000) },
      });
      return;
    }

    sendJSON(res, 404, { error: 'not found' });
  } catch (err) {
    sendJSON(res, 500, { error: String(err), traceId: traceID() });
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(JSON.stringify({
    level: 'INFO',
    event: 'listening',
    port,
    partition,
    guardian_partition: partition,
    targetURL,
    awsTargetURL,
  }));
});
