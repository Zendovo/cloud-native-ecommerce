package com.ecommerce.analytics;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.AggregateFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.base.DeliveryGuarantee;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.windowing.assigners.TumblingEventTimeWindows;
import org.apache.flink.streaming.api.windowing.time.Time;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

public class AnalyticsJob {

    private static final ObjectMapper objectMapper = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        String kafkaBootstrapServers = System.getenv().getOrDefault(
            "KAFKA_BOOTSTRAP_SERVERS",
            "localhost:9092"
        );
        String inputTopic = System.getenv().getOrDefault(
            "KAFKA_INPUT_TOPIC",
            "ecom-raw-events"
        );
        String outputTopic = System.getenv().getOrDefault(
            "KAFKA_OUTPUT_TOPIC",
            "ecom-analytics-results"
        );
        String dynamoTableName = System.getenv().getOrDefault(
            "DYNAMODB_TABLE",
            "ecommerce-analytics"
        );
        String awsRegion = System.getenv().getOrDefault(
            "AWS_REGION",
            "us-east-1"
        );
        String awsAccessKey = System.getenv("AWS_ACCESS_KEY_ID");
        String awsSecretKey = System.getenv("AWS_SECRET_ACCESS_KEY");

        StreamExecutionEnvironment env =
            StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(2);

        Properties kafkaProps = new Properties();
        kafkaProps.setProperty("security.protocol", "SASL_SSL");
        kafkaProps.setProperty("sasl.mechanism", "AWS_MSK_IAM");
        kafkaProps.setProperty(
            "sasl.jaas.config",
            "software.amazon.msk.auth.iam.IAMLoginModule required;"
        );
        kafkaProps.setProperty(
            "sasl.client.callback.handler.class",
            "software.amazon.msk.auth.iam.IAMClientCallbackHandler"
        );

        KafkaSource<String> source = KafkaSource.<String>builder()
            .setBootstrapServers(kafkaBootstrapServers)
            .setTopics(inputTopic)
            .setGroupId("flink-analytics-consumer")
            .setStartingOffsets(OffsetsInitializer.latest())
            .setValueOnlyDeserializer(new SimpleStringSchema())
            .setProperties(kafkaProps)
            .build();

        DataStream<String> rawEvents = env.fromSource(
            source,
            WatermarkStrategy.<String>forBoundedOutOfOrderness(
                Duration.ofSeconds(10)
            ).withTimestampAssigner((event, timestamp) -> {
                try {
                    JsonNode json = objectMapper.readTree(event);
                    String ts = json.get("timestamp").asText();
                    return Instant.parse(ts).toEpochMilli();
                } catch (Exception e) {
                    return System.currentTimeMillis();
                }
            }),
            "Kafka Source"
        );

        DataStream<String> aggregatedResults = rawEvents
            .map(json -> objectMapper.readTree(json))
            .filter(event -> event.has("product_id") && event.has("user_id"))
            .keyBy(event -> event.get("product_id").asText())
            .window(TumblingEventTimeWindows.of(Time.minutes(1)))
            .aggregate(new UniqueUserCountAggregator())
            .map(result -> {
                writeToDynamoDB(
                    result,
                    dynamoTableName,
                    awsRegion,
                    awsAccessKey,
                    awsSecretKey
                );
                return objectMapper.writeValueAsString(result);
            });

        Properties sinkKafkaProps = new Properties();
        sinkKafkaProps.setProperty("security.protocol", "SASL_SSL");
        sinkKafkaProps.setProperty("sasl.mechanism", "AWS_MSK_IAM");
        sinkKafkaProps.setProperty(
            "sasl.jaas.config",
            "software.amazon.msk.auth.iam.IAMLoginModule required;"
        );
        sinkKafkaProps.setProperty(
            "sasl.client.callback.handler.class",
            "software.amazon.msk.auth.iam.IAMClientCallbackHandler"
        );

        KafkaSink<String> sink = KafkaSink.<String>builder()
            .setBootstrapServers(kafkaBootstrapServers)
            .setRecordSerializer(
                KafkaRecordSerializationSchema.builder()
                    .setTopic(outputTopic)
                    .setValueSerializationSchema(new SimpleStringSchema())
                    .build()
            )
            .setDeliveryGuarantee(DeliveryGuarantee.AT_LEAST_ONCE)
            .setKafkaProducerConfig(sinkKafkaProps)
            .build();

        aggregatedResults.sinkTo(sink);

        env.execute("E-Commerce Analytics Job");
    }

    private static void writeToDynamoDB(
        AnalyticsResult result,
        String tableName,
        String region,
        String accessKey,
        String secretKey
    ) {
        try {
            DynamoDbClient dynamoClient = DynamoDbClient.builder()
                .region(Region.of(region))
                .credentialsProvider(
                    StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(accessKey, secretKey)
                    )
                )
                .build();

            Map<String, AttributeValue> item = new HashMap<>();
            item.put(
                "product_id",
                AttributeValue.builder().s(result.productId).build()
            );
            item.put(
                "window_start",
                AttributeValue.builder().s(result.windowStart).build()
            );
            item.put(
                "unique_user_count",
                AttributeValue.builder()
                    .n(String.valueOf(result.uniqueUserCount))
                    .build()
            );
            item.put(
                "window_end",
                AttributeValue.builder().s(result.windowEnd).build()
            );

            PutItemRequest request = PutItemRequest.builder()
                .tableName(tableName)
                .item(item)
                .build();

            dynamoClient.putItem(request);
            dynamoClient.close();
        } catch (Exception e) {
            System.err.println("Error writing to DynamoDB: " + e.getMessage());
        }
    }

    public static class UniqueUserAccumulator {

        public String productId;
        public Set<String> uniqueUsers = new HashSet<>();
        public long windowStart;
        public long windowEnd;
    }

    public static class AnalyticsResult {

        public String productId;
        public int uniqueUserCount;
        public String windowStart;
        public String windowEnd;

        public AnalyticsResult(
            String productId,
            int count,
            long start,
            long end
        ) {
            this.productId = productId;
            this.uniqueUserCount = count;
            this.windowStart = Instant.ofEpochMilli(start).toString();
            this.windowEnd = Instant.ofEpochMilli(end).toString();
        }
    }

    public static class UniqueUserCountAggregator
        implements
            AggregateFunction<
                JsonNode,
                UniqueUserAccumulator,
                AnalyticsResult
            > {

        @Override
        public UniqueUserAccumulator createAccumulator() {
            return new UniqueUserAccumulator();
        }

        @Override
        public UniqueUserAccumulator add(
            JsonNode event,
            UniqueUserAccumulator accumulator
        ) {
            if (accumulator.productId == null) {
                accumulator.productId = event.get("product_id").asText();
            }
            String userId = event.get("user_id").asText();
            accumulator.uniqueUsers.add(userId);

            try {
                String timestamp = event.get("timestamp").asText();
                long eventTime = Instant.parse(timestamp).toEpochMilli();
                if (accumulator.windowStart == 0) {
                    accumulator.windowStart = eventTime;
                }
                accumulator.windowEnd = eventTime;
            } catch (Exception e) {
                long now = System.currentTimeMillis();
                if (accumulator.windowStart == 0) {
                    accumulator.windowStart = now;
                }
                accumulator.windowEnd = now;
            }

            return accumulator;
        }

        @Override
        public AnalyticsResult getResult(UniqueUserAccumulator accumulator) {
            return new AnalyticsResult(
                accumulator.productId,
                accumulator.uniqueUsers.size(),
                accumulator.windowStart,
                accumulator.windowEnd
            );
        }

        @Override
        public UniqueUserAccumulator merge(
            UniqueUserAccumulator a,
            UniqueUserAccumulator b
        ) {
            a.uniqueUsers.addAll(b.uniqueUsers);
            if (b.windowStart < a.windowStart) {
                a.windowStart = b.windowStart;
            }
            if (b.windowEnd > a.windowEnd) {
                a.windowEnd = b.windowEnd;
            }
            return a;
        }
    }
}
