package com.orders.lambda;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;

import java.sql.Array;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * EventBridge-triggered Lambda (weekly). Moves orders older than 6 months
 * from Postgres → S3 as CSV, then deletes them from the source table.
 *
 * Safety: upload to S3 BEFORE deleting from Postgres. Both run in one
 * transaction — if anything fails, nothing is deleted.
 *
 * Batched (5,000 rows per run) so each invocation finishes inside Lambda's
 * 5-minute timeout. EventBridge can re-trigger if more rows remain.
 */
public class ArchiveOrdersHandler implements RequestHandler<Object, Map<String, Object>> {

    private static final S3Client S3 = S3Client.create();
    private static final SecretsManagerClient SECRETS = SecretsManagerClient.create();
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final int BATCH_SIZE = 5_000;

    @Override
    public Map<String, Object> handleRequest(Object event, Context context) {
        LambdaLogger log = context.getLogger();
        Map<String, Object> result = new HashMap<>();

        try {
            String secretArn = System.getenv("DB_SECRET_ARN");
            String dbHost = System.getenv("DB_HOST");
            String dbName = System.getenv("DB_NAME");
            String bucket = System.getenv("ARCHIVE_BUCKET");

            String secretString = SECRETS.getSecretValue(
                GetSecretValueRequest.builder().secretId(secretArn).build()
            ).secretString();
            JsonNode creds = JSON.readTree(secretString);

            String jdbcUrl = "jdbc:postgresql://" + dbHost + ":5432/" + dbName;

            int archived;
            List<UUID> ids = new ArrayList<>();
            StringBuilder csv = new StringBuilder();
            csv.append("id,customer_id,product_id,quantity,status,created_at\n");

            try (Connection conn = DriverManager.getConnection(
                    jdbcUrl,
                    creds.get("username").asText(),
                    creds.get("password").asText())) {

                conn.setAutoCommit(false);

                try (PreparedStatement select = conn.prepareStatement("""
                        SELECT id, customer_id, product_id, quantity, status, created_at
                        FROM orders.orders
                        WHERE created_at < NOW() - INTERVAL '6 months'
                        ORDER BY created_at
                        LIMIT ?
                        """)) {
                    select.setInt(1, BATCH_SIZE);
                    try (ResultSet rs = select.executeQuery()) {
                        while (rs.next()) {
                            UUID id = (UUID) rs.getObject(1);
                            ids.add(id);
                            csv.append(id).append(',')
                                    .append(safe(rs.getString(2))).append(',')
                                    .append(safe(rs.getString(3))).append(',')
                                    .append(rs.getInt(4)).append(',')
                                    .append(safe(rs.getString(5))).append(',')
                                    .append(rs.getTimestamp(6)).append('\n');
                        }
                    }
                }

                archived = ids.size();
                log.log("Found " + archived + " orders to archive");

                if (archived == 0) {
                    result.put("statusCode", 200);
                    result.put("archived", 0);
                    return result;
                }

                String archiveDate = LocalDate.now().toString();
                String key = "archive/orders/" + archiveDate + "/orders-" + System.currentTimeMillis() + ".csv";
                S3.putObject(
                    PutObjectRequest.builder()
                        .bucket(bucket)
                        .key(key)
                        .contentType("text/csv")
                        .build(),
                    RequestBody.fromString(csv.toString())
                );
                log.log("Uploaded archive to s3://" + bucket + "/" + key);

                try (PreparedStatement delete = conn.prepareStatement(
                        "DELETE FROM orders.orders WHERE id = ANY(?)")) {
                    Array idArray = conn.createArrayOf("uuid", ids.toArray());
                    delete.setArray(1, idArray);
                    int deleted = delete.executeUpdate();
                    log.log("Deleted " + deleted + " rows");
                }

                conn.commit();
                result.put("s3Key", key);
            }

            result.put("statusCode", 200);
            result.put("archived", archived);
            return result;

        } catch (Exception e) {
            log.log("ERROR: " + e.getClass().getName() + ": " + e.getMessage());
            result.put("statusCode", 500);
            result.put("error", e.getMessage());
            return result;
        }
    }

    private static String safe(String s) {
        if (s == null) return "";
        return s.contains(",") ? "\"" + s.replace("\"", "\"\"") + "\"" : s;
    }
}
