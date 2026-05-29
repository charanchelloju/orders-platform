package com.example.inventoryservice.repository;

import com.example.inventoryservice.domain.StockItem;
import org.springframework.data.jpa.repository.JpaRepository;

public interface StockRepository extends JpaRepository<StockItem, String> {
}
