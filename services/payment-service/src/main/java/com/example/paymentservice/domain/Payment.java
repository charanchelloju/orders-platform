package com.example.paymentservice.domain;

import jakarta.persistence.*;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "payments", schema = "payments")
public class Payment {

    @Id
    private UUID id;

    @Column(unique = true)
    private UUID orderId;          // idempotency key — one payment per order

    private String customerId;
    private int amountCents;

    @Enumerated(EnumType.STRING)
    private PaymentStatus status;

    private Instant processedAt;

    public Payment() {}

    public Payment(UUID orderId, String customerId, int amountCents, PaymentStatus status) {
        this.id = UUID.randomUUID();
        this.orderId = orderId;
        this.customerId = customerId;
        this.amountCents = amountCents;
        this.status = status;
        this.processedAt = Instant.now();
    }

    public UUID getId() { return id; }
    public UUID getOrderId() { return orderId; }
    public String getCustomerId() { return customerId; }
    public int getAmountCents() { return amountCents; }
    public PaymentStatus getStatus() { return status; }
    public Instant getProcessedAt() { return processedAt; }
}
