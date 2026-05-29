package com.example.paymentservice.service;

import com.example.paymentservice.domain.Payment;
import com.example.paymentservice.domain.PaymentStatus;
import com.example.paymentservice.repository.PaymentRepository;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

@Service
public class PaymentService {

    private static final Logger log = LoggerFactory.getLogger(PaymentService.class);

    private final PaymentRepository repo;
    private final KafkaTemplate<String, String> kafkaTemplate;
    private final ObjectMapper objectMapper;

    @Value("${app.kafka.topics.payments:payments}")
    private String paymentsTopic;

    public PaymentService(PaymentRepository repo,
                          KafkaTemplate<String, String> kafkaTemplate,
                          ObjectMapper objectMapper) {
        this.repo = repo;
        this.kafkaTemplate = kafkaTemplate;
        this.objectMapper = objectMapper;
    }

    /**
     * Idempotent: if a payment for this orderId already exists, return it.
     * Otherwise process and persist.
     */
    @Transactional
    public Payment processPayment(UUID orderId, String customerId, int quantity) {
        return repo.findByOrderId(orderId).orElseGet(() -> {
            int amountCents = quantity * 1000;     // mock price: $10 per item
            PaymentStatus status = ThreadLocalRandom.current().nextInt(10) == 0
                    ? PaymentStatus.FAILED         // 10% mock failure rate
                    : PaymentStatus.SUCCEEDED;

            Payment payment = repo.save(new Payment(orderId, customerId, amountCents, status));
            publishPaymentEvent(payment);
            log.info("Processed payment for order {} → {}", orderId, status);
            return payment;
        });
    }

    private void publishPaymentEvent(Payment payment) {
        try {
            String json = objectMapper.writeValueAsString(Map.of(
                    "paymentId",  payment.getId().toString(),
                    "orderId",    payment.getOrderId().toString(),
                    "customerId", payment.getCustomerId(),
                    "amountCents", payment.getAmountCents(),
                    "status",     payment.getStatus().name(),
                    "processedAt", payment.getProcessedAt().toString()
            ));
            kafkaTemplate.send(paymentsTopic, payment.getOrderId().toString(), json);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize payment event", e);
        }
    }
}
