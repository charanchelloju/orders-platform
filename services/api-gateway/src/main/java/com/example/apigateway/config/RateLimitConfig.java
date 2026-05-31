package com.example.apigateway.config;

import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import reactor.core.publisher.Mono;

/**
 * Resolves the rate-limit key per authenticated user (JWT sub claim).
 * Unauthenticated requests get bucketed under the literal key "anonymous"
 * so they share one quota and can't bypass per-user limits.
 *
 * Used by the RequestRateLimiter filter declared in application.yml.
 */
@Configuration
public class RateLimitConfig {

    @Bean
    public KeyResolver userKeyResolver() {
        return exchange -> ReactiveSecurityContextHolder.getContext()
            .map(ctx -> ctx.getAuthentication())
            .filter(a -> a instanceof JwtAuthenticationToken)
            .map(a -> ((JwtAuthenticationToken) a).getToken().getSubject())
            .defaultIfEmpty("anonymous");
    }
}
