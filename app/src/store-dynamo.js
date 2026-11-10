'use strict';
// =============================================================================
// store-dynamo.js — keeps game data in Amazon DynamoDB (a managed NoSQL database).
//
// ONE table holds everything ("single-table design"). Each item has two keys:
//
//   pk (partition key)   sk (sort key)                 what it is
//   ------------------   ---------------------------   ---------------------------
//   STATE                CURRENT                       the live game (rope, scores)
//   INCIDENT             2026-11-10T08:00:00.000Z      one crash + its recovery
//   ROUND                2026-11-10T08:05:00.000Z      one finished round
//
// Because the sort key is a timestamp, "give me the latest 20 incidents" is a
// single cheap Query, newest first.
//
// NO access keys are stored anywhere. On EC2 the AWS SDK automatically uses the
// temporary credentials of the server's IAM role.
// =============================================================================

const { DynamoDBClient, DescribeTableCommand } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } = require('@aws-sdk/lib-dynamodb');

class DynamoStore {
  constructor({ region, tableName, rawClient, docClient }) {
    this.kind = 'dynamo';
    this.tableName = tableName;
    // maxAttempts: retry a failed request up to 3 times before giving up.
    this.raw = rawClient || new DynamoDBClient({ region, maxAttempts: 3 });
    this.doc =
      docClient ||
      DynamoDBDocumentClient.from(this.raw, { marshallOptions: { removeUndefinedValues: true } });
  }

  async loadState() {
    const result = await this.doc.send(
      new GetCommand({
        TableName: this.tableName,
        Key: { pk: 'STATE', sk: 'CURRENT' },
        ConsistentRead: true, // always read the very latest write
      })
    );
    return result.Item ? result.Item.data : null;
  }

  async saveState(state) {
    await this.doc.send(
      new PutCommand({
        TableName: this.tableName,
        Item: { pk: 'STATE', sk: 'CURRENT', data: state, updatedAt: new Date().toISOString() },
      })
    );
  }

  /** Create or update one incident. Put replaces the whole item. */
  async putIncident(incident) {
    await this.doc.send(
      new PutCommand({
        TableName: this.tableName,
        Item: { ...incident, pk: 'INCIDENT', sk: incident.id },
      })
    );
  }

  async listIncidents(limit = 20) {
    return this._listNewest('INCIDENT', limit);
  }

  async addRound(round) {
    await this.doc.send(
      new PutCommand({
        TableName: this.tableName,
        Item: { ...round, pk: 'ROUND', sk: new Date(round.finishedAt).toISOString() },
      })
    );
  }

  async listRounds(limit = 5) {
    return this._listNewest('ROUND', limit);
  }

  async _listNewest(pk, limit) {
    const result = await this.doc.send(
      new QueryCommand({
        TableName: this.tableName,
        KeyConditionExpression: '#pk = :pk',
        ExpressionAttributeNames: { '#pk': 'pk' },
        ExpressionAttributeValues: { ':pk': pk },
        ScanIndexForward: false, // newest first
        Limit: limit,
        ConsistentRead: true,
      })
    );
    // Hide the internal keys from the rest of the app.
    return (result.Items || []).map(({ pk: _pk, sk: _sk, ...rest }) => rest);
  }

  /** Health check: can we reach the table, and is it ACTIVE? */
  async check() {
    const result = await this.raw.send(new DescribeTableCommand({ TableName: this.tableName }));
    const status = result.Table?.TableStatus || 'UNKNOWN';
    return { ok: status === 'ACTIVE', kind: this.kind, detail: `table ${this.tableName} is ${status}` };
  }
}

module.exports = { DynamoStore };
