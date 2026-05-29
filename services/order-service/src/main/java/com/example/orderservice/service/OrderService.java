package com.example.orderservice.service;

import com.example.orderservice.domain.Order;
import com.example.orderservice.outbox.OutboxEvent;
import com.example.orderservice.repository.OrderRepository;
import com.example.orderservice.repository.OutboxRepository;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.UUID;

@Service
public class OrderService {

    private final OrderRepository orderRepo;
    private final OutboxRepository outboxRepo;
    private final ObjectMapper objectMapper;

    public OrderService(OrderRepository orderRepo, OutboxRepository outboxRepo, ObjectMapper objectMapper) {
        this.orderRepo = orderRepo;
        this.outboxRepo = outboxRepo;
        this.objectMapper = objectMapper;
    }

    /**
     * Creates an order AND writes an outbox event in the same DB transaction.
     * The OutboxPublisher will later push the event to Kafka.
     * This is the transactional outbox pattern — atomic DB + event publish.
     */
    @Transactional
    public Order createOrder(String customerId, String productId, int quantity) {
        Order saved = orderRepo.save(new Order(customerId, productId, quantity));

        outboxRepo.save(new OutboxEvent(
                "Order",
                saved.getId().toString(),
                "OrderCreated",
                "orders",
                toJson(Map.of(
                        "orderId",    saved.getId().toString(),
                        "customerId", saved.getCustomerId(),
                        "productId",  saved.getProductId(),
                        "quantity",   saved.getQuantity(),
                        "status",     saved.getStatus().name(),
                        "createdAt",  saved.getCreatedAt().toString()
                ))
        ));

        return saved;
    }

    @Transactional
    public void applyPaymentResult(UUID orderId, boolean success) {
        orderRepo.findById(orderId).ifPresent(order -> {
            if (success) order.markPaid();
            else order.markPaymentFailed();
            orderRepo.save(order);
        });
    }

    private String toJson(Map<String, Object> payload) {
        try {
            return objectMapper.writeValueAsString(payload);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize event payload", e);
        }
    }
}
