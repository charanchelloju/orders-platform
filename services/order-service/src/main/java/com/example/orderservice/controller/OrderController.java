package com.example.orderservice.controller;

import com.example.orderservice.domain.Order;
import com.example.orderservice.repository.OrderRepository;
import com.example.orderservice.service.OrderService;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Positive;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderService orderService;
    private final OrderRepository orderRepo;

    public OrderController(OrderService orderService, OrderRepository orderRepo) {
        this.orderService = orderService;
        this.orderRepo = orderRepo;
    }

    /**
     * Create an order. Requires ROLE_ORDERS_WRITE (Keycloak realm role
     * "ORDERS_WRITE" → ROLE_ORDERS_WRITE authority).
     */
    @PostMapping
    @PreAuthorize("hasRole('ORDERS_WRITE')")
    public ResponseEntity<Order> create(@RequestBody CreateOrderRequest req) {
        Order saved = orderService.createOrder(req.customerId(), req.productId(), req.quantity());
        return ResponseEntity.ok(saved);
    }

    /**
     * List orders. Requires ROLE_USER — any authenticated user.
     */
    @GetMapping
    @PreAuthorize("hasRole('USER')")
    public List<Order> list() {
        return orderRepo.findAll();
    }

    /**
     * Get one order. Requires ROLE_USER.
     */
    @GetMapping("/{id}")
    @PreAuthorize("hasRole('USER')")
    public ResponseEntity<Order> get(@PathVariable UUID id) {
        return orderRepo.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    public record CreateOrderRequest(
            @NotBlank String customerId,
            @NotBlank String productId,
            @Positive int quantity
    ) {}
}
