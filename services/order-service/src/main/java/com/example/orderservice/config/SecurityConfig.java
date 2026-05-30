package com.example.orderservice.config;

import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.web.SecurityFilterChain;

import java.util.Collection;
import java.util.List;
import java.util.Map;

/**
 * Security configuration toggled by the presence of the issuer URI property.
 *
 * AWS profile (issuer-uri set):
 *   - All /api/** requires a valid Bearer JWT
 *   - Roles read from realm_access.roles (Keycloak format)
 *   - Mapped to ROLE_* authorities for @PreAuthorize
 *
 * Local / docker (issuer-uri blank):
 *   - permitAll on every endpoint
 *
 * Actuator endpoints are always public so K8s probes work without a token.
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    /**
     * JWT-protected chain. Active only when issuer-uri is configured.
     */
    @Bean
    @ConditionalOnProperty(name = "spring.security.oauth2.resourceserver.jwt.issuer-uri")
    public SecurityFilterChain protectedFilterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/**").permitAll()
                .anyRequest().authenticated())
            .oauth2ResourceServer(o -> o.jwt(j -> j.jwtAuthenticationConverter(jwtAuthConverter())));
        return http.build();
    }

    /**
     * Permissive chain used in local dev and Docker Compose when no IdP
     * is configured. Kicks in only if the protected chain didn't.
     */
    @Bean
    @ConditionalOnMissingBean(SecurityFilterChain.class)
    public SecurityFilterChain openFilterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
        return http.build();
    }

    /**
     * Map Keycloak realm roles → Spring authorities.
     *
     * Keycloak JWT:
     *   { "realm_access": { "roles": ["USER", "ORDERS_WRITE"] } }
     *
     * Result: ROLE_USER, ROLE_ORDERS_WRITE — usable in @PreAuthorize("hasRole('USER')").
     *
     * To swap to Azure AD: change the claim path from "realm_access.roles"
     * to "roles" (Azure AD app roles claim). Nothing else changes.
     */
    private JwtAuthenticationConverter jwtAuthConverter() {
        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(SecurityConfig::extractRoles);
        return converter;
    }

    @SuppressWarnings("unchecked")
    private static Collection<GrantedAuthority> extractRoles(Jwt jwt) {
        Map<String, Object> realmAccess = jwt.getClaim("realm_access");
        if (realmAccess == null) return List.of();
        Collection<String> roles = (Collection<String>) realmAccess.get("roles");
        if (roles == null) return List.of();
        return roles.stream()
            .map(r -> (GrantedAuthority) new SimpleGrantedAuthority("ROLE_" + r))
            .toList();
    }
}
