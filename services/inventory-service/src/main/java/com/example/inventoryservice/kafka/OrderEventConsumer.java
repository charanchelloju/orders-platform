package com.example.inventoryservice.kafka;

import com.example.inventoryservice.service.InventoryService;
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

    private final InventoryService inventoryService;
    private final ObjectMapper objectMapper;

    public OrderEventConsumer(InventoryService inventoryService, ObjectMapper objectMapper) {
        this.inventoryService = inventoryService;
        this.objectMapper = objectMapper;
    }

    @KafkaListener(
            topics = "${app.kafka.topics.orders:orders}",
            groupId = "${spring.kafka.consumer.group-id:inventory-service}",
            containerFactory = "kafkaListenerContainerFactory"
    )
    public void onOrderCreated(String payload, Acknowledgment ack) {
        try {
            JsonNode node = objectMapper.readTree(payload);
            UUID orderId = UUID.fromString(node.get("orderId").asText());
            String productId = node.get("productId").asText();
            int quantity = node.get("quantity").asInt();

            inventoryService.decrementStock(orderId, productId, quantity);
            ack.acknowledge();
        } catch (Exception e) {
            log.error("Failed to process order event: {}", payload, e);
            throw new RuntimeException(e);
        }
    }
}
