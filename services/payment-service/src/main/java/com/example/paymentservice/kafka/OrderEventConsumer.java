package com.example.paymentservice.kafka;

import com.example.paymentservice.service.PaymentService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.stereotype.Component;

import java.util.UUID;

@Component
public class OrderEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(OrderEventConsumer.class);

    private final PaymentService paymentService;
    private final ObjectMapper objectMapper;

    public OrderEventConsumer(PaymentService paymentService, ObjectMapper objectMapper) {
        this.paymentService = paymentService;
        this.objectMapper = objectMapper;
    }

    @KafkaListener(
            topics = "${app.kafka.topics.orders:orders}",
            groupId = "${spring.kafka.consumer.group-id:payment-service}",
            containerFactory = "kafkaListenerContainerFactory"
    )
    public void onOrderCreated(String payload, Acknowledgment ack) {
        try {
            JsonNode node = objectMapper.readTree(payload);
            UUID orderId = UUID.fromString(node.get("orderId").asText());
            String customerId = node.get("customerId").asText();
            int quantity = node.get("quantity").asInt();

            paymentService.processPayment(orderId, customerId, quantity);
            ack.acknowledge();
        } catch (Exception e) {
            log.error("Failed to process order event: {}", payload, e);
            throw new RuntimeException(e);     // triggers DLT routing
        }
    }
}
