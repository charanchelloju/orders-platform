package com.example.orderservice.config;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.config.TopicBuilder;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.ContainerProperties.AckMode;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.common.TopicPartition;
import org.springframework.util.backoff.FixedBackOff;

@Configuration
public class KafkaConfig {

    @Value("${app.kafka.topics.orders:orders}")
    private String ordersTopic;

    @Value("${app.kafka.topics.payments:payments}")
    private String paymentsTopic;

    @Value("${app.kafka.partitions.orders:6}")
    private int ordersPartitions;

    @Value("${app.kafka.partitions.payments:3}")
    private int paymentsPartitions;

    @Value("${app.kafka.replication-factor:1}")
    private short replicationFactor;

    @Bean
    public NewTopic ordersTopicDef() {
        return TopicBuilder.name(ordersTopic)
                .partitions(ordersPartitions)
                .replicas(replicationFactor)
                .build();
    }

    @Bean
    public NewTopic ordersDltTopicDef() {
        return TopicBuilder.name(ordersTopic + ".DLT")
                .partitions(ordersPartitions)
                .replicas(replicationFactor)
                .build();
    }

    @Bean
    public NewTopic paymentsDltTopicDef() {
        return TopicBuilder.name(paymentsTopic + ".DLT")
                .partitions(paymentsPartitions)
                .replicas(replicationFactor)
                .build();
    }

    /**
     * Manual ack listener container so consumers commit AFTER successful processing.
     * Failed records are retried 3 times then routed to {topic}.DLT.
     */
    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, String> kafkaListenerContainerFactory(
            ConsumerFactory<String, String> consumerFactory,
            KafkaTemplate<String, String> kafkaTemplate) {

        ConcurrentKafkaListenerContainerFactory<String, String> factory =
                new ConcurrentKafkaListenerContainerFactory<>();
        factory.setConsumerFactory(consumerFactory);
        factory.getContainerProperties().setAckMode(AckMode.MANUAL_IMMEDIATE);

        DeadLetterPublishingRecoverer recoverer = new DeadLetterPublishingRecoverer(
                kafkaTemplate,
                (ConsumerRecord<?, ?> record, Exception ex) ->
                        new TopicPartition(record.topic() + ".DLT", record.partition()));

        DefaultErrorHandler errorHandler = new DefaultErrorHandler(recoverer, new FixedBackOff(1000L, 3));
        factory.setCommonErrorHandler(errorHandler);

        return factory;
    }
}
