idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    REQUIRES esp_eth esp_driver_gpio esp_driver_spi esp_driver_ledc driver spi_flash nvs_flash esp_wifi esp_netif esp_http_client esp_http_server cjson mdns esp_timer app_update
)
