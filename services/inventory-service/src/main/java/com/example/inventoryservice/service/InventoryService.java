package com.example.inventoryservice.service;

import com.example.inventoryservice.domain.ProcessedOrder;
import com.example.inventoryservice.domain.StockItem;
import com.example.inventoryservice.repository.ProcessedOrderRepository;
import com.example.inventoryservice.repository.StockRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class InventoryService {

    private static final Logger log = LoggerFactory.getLogger(InventoryService.class);

    private static final int DEFAULT_STOCK = 100;

    private final StockRepository stockRepo;
    private final ProcessedOrderRepository processedRepo;

    public InventoryService(StockRepository stockRepo, ProcessedOrderRepository processedRepo) {
        this.stockRepo = stockRepo;
        this.processedRepo = processedRepo;
    }

    @Transactional
    public void decrementStock(UUID orderId, String productId, int quantity) {
        if (processedRepo.existsById(orderId)) {
            log.info("Skipping order {} — already processed (idempotency)", orderId);
            return;
        }

        StockItem stock = stockRepo.findById(productId)
                .orElseGet(() -> stockRepo.save(new StockItem(productId, DEFAULT_STOCK)));

        if (stock.decrement(quantity)) {
            stockRepo.save(stock);
            processedRepo.save(new ProcessedOrder(orderId));
            log.info("Decremented stock for product {} by {}; remaining: {}",
                    productId, quantity, stock.getQuantityAvailable());
        } else {
            log.warn("Insufficient stock for product {} — needed {}, have {}",
                    productId, quantity, stock.getQuantityAvailable());
            // Still mark as processed so we don't retry forever
            processedRepo.save(new ProcessedOrder(orderId));
        }
    }
}
