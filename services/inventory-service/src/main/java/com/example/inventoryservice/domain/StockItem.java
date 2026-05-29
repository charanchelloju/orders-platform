package com.example.inventoryservice.domain;

import jakarta.persistence.*;

@Entity
@Table(name = "stock", schema = "inventory")
public class StockItem {

    @Id
    private String productId;

    private int quantityAvailable;

    public StockItem() {}

    public StockItem(String productId, int quantityAvailable) {
        this.productId = productId;
        this.quantityAvailable = quantityAvailable;
    }

    public boolean decrement(int qty) {
        if (this.quantityAvailable < qty) return false;
        this.quantityAvailable -= qty;
        return true;
    }

    public String getProductId() { return productId; }
    public int getQuantityAvailable() { return quantityAvailable; }
}
