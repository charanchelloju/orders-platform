package com.example.inventoryservice.domain;

import jakarta.persistence.*;

import java.time.Instant;
import java.util.UUID;

/**
 * Idempotency log — records every orderId we've already processed.
 * If the same orderId comes again (Kafka redelivery / at-least-once),
 * we skip the stock decrement.
 */
@Entity
@Table(name = "processed_orders", schema = "inventory")
public class ProcessedOrder {

    @Id
    private UUID orderId;

    private Instant processedAt;

    public ProcessedOrder() {}

    public ProcessedOrder(UUID orderId) {
        this.orderId = orderId;
        this.processedAt = Instant.now();
    }

    public UUID getOrderId() { return orderId; }
    public Instant getProcessedAt() { return processedAt; }
}
