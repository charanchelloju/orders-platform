package com.example.apigateway.filter;

import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.core.Ordered;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Injects user identity from the validated JWT into downstream request headers.
 * Backend services trust these headers (they are unreachable except via this
 * gateway thanks to NetworkPolicy + ClusterIP-only Service).
 *
 * Headers added:
 *   X-User-Id     - JWT sub claim
 *   X-User-Name   - preferred_username claim
 *   X-User-Email  - email claim
 *   X-User-Roles  - comma-joined realm roles (from realm_access.roles)
 *
 * The original Authorization header is removed so the JWT does not travel
 * any further than necessary.
 */
@Component
public class HeaderInjectionFilter implements GlobalFilter, Ordered {

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        return ReactiveSecurityContextHolder.getContext()
            .map(ctx -> ctx.getAuthentication())
            .filter(auth -> auth instanceof JwtAuthenticationToken)
            .map(auth -> ((JwtAuthenticationToken) auth).getToken())
            .map(jwt -> mutateRequest(exchange, jwt))
            .defaultIfEmpty(exchange)
            .flatMap(chain::filter);
    }

    @SuppressWarnings("unchecked")
    private ServerWebExchange mutateRequest(ServerWebExchange exchange, Jwt jwt) {
        String sub = jwt.getSubject();
        String username = jwt.getClaimAsString("preferred_username");
        String email = jwt.getClaimAsString("email");

        Map<String, Object> realmAccess = jwt.getClaim("realm_access");
        String roles = "";
        if (realmAccess != null && realmAccess.get("roles") instanceof List<?>) {
            roles = ((List<String>) realmAccess.get("roles")).stream()
                .collect(Collectors.joining(","));
        }

        final String rolesFinal = roles;

        return exchange.mutate()
            .request(r -> r.headers(h -> {
                if (sub != null)      h.set("X-User-Id", sub);
                if (username != null) h.set("X-User-Name", username);
                if (email != null)    h.set("X-User-Email", email);
                h.set("X-User-Roles", rolesFinal);
                h.remove("Authorization");
            }))
            .build();
    }

    @Override
    public int getOrder() {
        return -1; // run before the routing filter
    }
}
