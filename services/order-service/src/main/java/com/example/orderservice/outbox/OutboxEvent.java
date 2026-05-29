package com.example.orderservice.outbox;

import jakarta.persistence.*;

import java.time.Instant;
import java.util.UUID;

/**
 * Outbox table for the transactional outbox pattern.
 *
 * When the application persists business data, it ALSO writes a row here
 * in the SAME DB transaction. A scheduled publisher reads pending rows
 * and publishes them to Kafka. This guarantees the business write and the
 * event publish are atomic (both happen or neither happens) — solving the
 * dual-write problem.
 */
@Entity
@Table(name = "outbox", schema = "orders")
public class OutboxEvent {

    @Id
    private UUID id;

    private String aggregateType;
    private String aggregateId;
    private String eventType;
    private String topic;

    @Column(columnDefinition = "TEXT")
    private String payload;

    private Instant createdAt;
    private Instant publishedAt;

    public OutboxEvent() {}

    public OutboxEvent(String aggregateType, String aggregateId,
                       String eventType, String topic, String payload) {
        this.id = UUID.randomUUID();
        this.aggregateType = aggregateType;
        this.aggregateId = aggregateId;
        this.eventType = eventType;
        this.topic = topic;
        this.payload = payload;
        this.createdAt = Instant.now();
    }

    public void markPublished() {
        this.publishedAt = Instant.now();
    }

    public UUID getId() { return id; }
    public String getAggregateType() { return aggregateType; }
    public String getAggregateId() { return aggregateId; }
    public String getEventType() { return eventType; }
    public String getTopic() { return topic; }
    public String getPayload() { return payload; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getPublishedAt() { return publishedAt; }
}
