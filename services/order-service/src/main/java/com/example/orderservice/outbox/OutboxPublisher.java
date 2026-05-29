package com.example.orderservice.outbox;

import com.example.orderservice.repository.OutboxRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * Periodically reads unpublished outbox events and publishes them to Kafka.
 * Idempotent: if Kafka send succeeds but DB update fails, the next tick
 * may re-publish — downstream consumers must dedupe (idempotent processing).
 */
@Component
public class OutboxPublisher {

    private static final Logger log = LoggerFactory.getLogger(OutboxPublisher.class);

    private final OutboxRepository outboxRepo;
    private final KafkaTemplate<String, String> kafkaTemplate;

    public OutboxPublisher(OutboxRepository outboxRepo, KafkaTemplate<String, String> kafkaTemplate) {
        this.outboxRepo = outboxRepo;
        this.kafkaTemplate = kafkaTemplate;
    }

    @Scheduled(fixedDelayString = "${app.outbox.poll-interval-ms:2000}")
    @Transactional
    public void publishPending() {
        List<OutboxEvent> pending = outboxRepo.findUnpublished();
        if (pending.isEmpty()) return;

        log.debug("Publishing {} pending outbox events", pending.size());
        for (OutboxEvent event : pending) {
            try {
                kafkaTemplate.send(event.getTopic(), event.getAggregateId(), event.getPayload()).get();
                event.markPublished();
                outboxRepo.save(event);
                log.info("Published outbox event {} to topic {}", event.getId(), event.getTopic());
            } catch (Exception e) {
                log.warn("Failed to publish outbox event {}; will retry next tick", event.getId(), e);
            }
        }
    }
}
