package com.example.orderservice.kafka;

import com.example.orderservice.service.OrderService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * Listens to the "payments" topic to update order status (PAID / PAYMENT_FAILED).
 * This is the "consumer" half of the order-service — it also produces (via outbox).
 *
 * Manual ack: only commits after the DB update succeeds → at-least-once.
 * applyPaymentResult() is idempotent (UPDATE based on status enum).
 */
@Component
public class PaymentEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(PaymentEventConsumer.class);

    private final OrderService orderService;
    private final ObjectMapper objectMapper;

    public PaymentEventConsumer(OrderService orderService, ObjectMapper objectMapper) {
        this.orderService = orderService;
        this.objectMapper = objectMapper;
    }

    @KafkaListener(
            topics = "${app.kafka.topics.payments:payments}",
            groupId = "${spring.kafka.consumer.group-id:order-service}",
            containerFactory = "kafkaListenerContainerFactory"
    )
    public void onPaymentEvent(String payload, Acknowledgment ack) {
        try {
            JsonNode node = objectMapper.readTree(payload);
            UUID orderId = UUID.fromString(node.get("orderId").asText());
            boolean success = "SUCCEEDED".equals(node.get("status").asText());

            orderService.applyPaymentResult(orderId, success);
            log.info("Applied payment result to order {}: success={}", orderId, success);

            ack.acknowledge();
        } catch (Exception e) {
            log.error("Failed to process payment event: {}", payload, e);
            throw new RuntimeException(e);
        }
    }
}
