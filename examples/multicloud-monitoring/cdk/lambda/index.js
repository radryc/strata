'use strict';

const AWSXRay = require('aws-xray-sdk-core');
const { flush, tracer } = require('./tracing');
const { DynamoDBClient, PutItemCommand } = require('@aws-sdk/client-dynamodb');
const {
  SpanStatusCode,
  context,
  propagation,
} = require('@opentelemetry/api');

// In Lambda the X-Ray SDK installs a facade segment from the invocation trace
// header at module load (see aws-xray-sdk-core/env/aws_lambda). Wrapping the
// client adds one `DynamoDB` subsegment per call to that trace, so the table
// write is visible in X-Ray alongside the OTel span. The import must happen
// before the client is constructed so the middleware is attached to it.
const ddb = AWSXRay.captureAWSv3Client(new DynamoDBClient({}));

function traceCarrier(record) {
  const carrier = {};
  for (const [key, value] of Object.entries(record.messageAttributes || {})) {
    if (value && typeof value.stringValue === 'string') {
      carrier[key] = value.stringValue;
    }
  }
  // SQS system attribute; used as a fallback when an upstream sender only
  // provides the AWS X-Ray header.
  if (record.attributes && record.attributes.AWSTraceHeader) {
    carrier['x-amzn-trace-id'] = record.attributes.AWSTraceHeader;
  }
  return carrier;
}

exports.handler = async (event) => {
  const records = event.Records || [
    { messageId: 'manual-' + Date.now(), body: JSON.stringify({ action: 'ping' }) },
  ];

  for (const record of records) {
    const parent = propagation.extract(context.active(), traceCarrier(record));
    await context.with(parent, async () => {
      await tracer.startActiveSpan('lambda.process', async (span) => {
        try {
          const itemId = record.messageId || 'item-' + Date.now();
          const now = new Date().toISOString();
          await ddb.send(
            new PutItemCommand({
              TableName: process.env.TABLE_NAME,
              Item: {
                itemId: { S: itemId },
                partition: { S: process.env.PARTITION_NAME || 'unknown' },
                division: { S: process.env.DIVISION_NAME || 'unknown' },
                department: { S: process.env.DEPARTMENT_NAME || 'unknown' },
                payload: { S: record.body || '{}' },
                processedAt: { S: now },
              },
            }),
          );
          span.setAttribute('messaging.message.id', itemId);
          console.log(
            JSON.stringify({
              level: 'INFO',
              service: (process.env.PARTITION_NAME || 'app') + '-processor',
              guardian_partition: process.env.PARTITION_NAME,
              division: process.env.DIVISION_NAME,
              department: process.env.DEPARTMENT_NAME,
              event: 'sqs_event_persisted_to_dynamodb',
              itemId,
              table: process.env.TABLE_NAME,
              timestamp: now,
            }),
          );
        } catch (err) {
          span.recordException(err);
          span.setStatus({ code: SpanStatusCode.ERROR, message: String(err) });
          throw err;
        } finally {
          span.end();
        }
      });
    });
  }

  // Lambda freezes immediately after the handler returns. Wait for the
  // SimpleSpanProcessor to finish the OTLP export before returning.
  await flush();
  return { statusCode: 200, processed: records.length };
};
