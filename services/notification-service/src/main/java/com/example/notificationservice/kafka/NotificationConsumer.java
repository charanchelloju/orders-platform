package com.example.notificationservice.kafka;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.stereotype.Component;

/**
 * Pure consumer service. Listens to BOTH orders and payments topics, simulates
 * sending notifications (email/SMS). In real production, would call SendGrid /
 * Twilio / SES — here it just logs.
 *
 * Demonstrates one consumer service subscribed to multiple topics.
 */
@Component
public class NotificationConsumer {

    private static final Logger log = LoggerFactory.getLogger(NotificationConsumer.class);

    private final ObjectMapper objectMapper;

    public NotificationConsumer(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    @KafkaListener(
            topics = "${app.kafka.topics.orders:orders}",
            groupId = "${spring.kafka.consumer.group-id:notification-service}",
            containerFactory = "kafkaListenerContainerFactory"
    )
    public void onOrderCreated(String payload, Acknowledgment ack) {
        try {
            JsonNode node = objectMapper.readTree(payload);
            String customerId = node.get("customerId").asText();
            String productId  = node.get("productId").asText();
            int    quantity   = node.get("quantity").asInt();

            log.info("📧 [Email mock] To: {} — Your order for {} (qty {}) has been received.",
                    customerId, productId, quantity);
            ack.acknowledge();
        } catch (Exception e) {
            log.error("Failed to process order event: {}", payload, e);
            throw new RuntimeException(e);
        }
    }

    @KafkaListener(
            topics = "${app.kafka.topics.payments:payments}",
            groupId = "${spring.kafka.consumer.group-id:notification-service}",
            containerFactory = "kafkaListenerContainerFactory"
    )
    public void onPaymentProcessed(String payload, Acknowledgment ack) {
        try {
            JsonNode node = objectMapper.readTree(payload);
            String customerId = node.get("customerId").asText();
            String status     = node.get("status").asText();
            String orderId    = node.get("orderId").asText();

            if ("SUCCEEDED".equals(status)) {
                log.info("📧 [Email mock] To: {} — Payment for order {} succeeded ✓", customerId, orderId);
            } else {
                log.info("📧 [Email mock] To: {} — Payment for order {} FAILED ✗ — please retry",
                        customerId, orderId);
            }
            ack.acknowledge();
        } catch (Exception e) {
            log.error("Failed to process payment event: {}", payload, e);
            throw new RuntimeException(e);
        }
    }
}
