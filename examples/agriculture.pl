%% DALI2 Example: Smart Agriculture MAS
%% Ported from the original DALI agriculture case study (dalia/case_study_smart_agriculture).
%%
%% Agents (6):
%%   - soil_sensor:            receives soil readings, validates via internal events
%%   - weather_monitor:        receives weather data, validates via internal events
%%   - crop_advisor:           analyzes data with AI, decides actions (irrigate/reduce/advisory)
%%   - irrigation_controller:  activates irrigation or reduces water supply
%%   - farmer_agent:           receives advisories and status updates
%%   - logger:                 logs all events
%%
%% Flow:
%%   read_soil(25, 6.5, north) → soil_sensor validates → abnormal → soil_report to crop_advisor
%%   → crop_advisor decides action → irrigate/reduce_water/advisory → farmer notified
%%
%% Run:   AGENT_FILE=examples/agriculture.pl docker compose up --build
%% Or:    swipl -l src/server.pl -g main -- 8080 examples/agriculture.pl

%% ============================================================
%% SOIL SENSOR — receives readings, validates via internal events
%% ============================================================
%%
%% Pattern from DALI: read_soilE stores state → internal events check
%% if readings are abnormal (moisture < 30 or > 80, pH outside 5.5–7.5).
%% Only abnormal readings are forwarded to crop_advisor as soil_report.

:- agent(soil_sensor, [cycle(1)]).

%% Receive soil reading, store state for internal event validation
soil_sensor:on(read_soil(Moisture, PH, Field)) :-
    log("Soil reading: M=~w pH=~w Field=~w", [Moisture, PH, Field]),
    assert_belief(soil_state(Moisture, PH, Field)),
    send(logger, log_event(soil_reading, soil_sensor, [Moisture, PH, Field])).

%% Internal event: abnormal soil → send report to crop_advisor
soil_sensor:internal(soil_alert_check, [forever]) :-
    believes(soil_state(Moisture, PH, Field)),
    (Moisture < 30 ; Moisture > 80 ; PH < 5.5 ; PH > 7.5),
    log("SOIL ALERT: M=~w pH=~w Field=~w", [Moisture, PH, Field]),
    retract_belief(soil_state(Moisture, PH, Field)),
    send(crop_advisor, soil_report(Moisture, PH, Field)).

%% Internal event: normal soil — just clear state and log
soil_sensor:internal(soil_normal_check, [forever]) :-
    believes(soil_state(Moisture, PH, Field)),
    Moisture >= 30, Moisture =< 80, PH >= 5.5, PH =< 7.5,
    log("SOIL NORMAL: M=~w pH=~w Field=~w", [Moisture, PH, Field]),
    retract_belief(soil_state(Moisture, PH, Field)).

%% ============================================================
%% WEATHER MONITOR — receives weather data, validates via internal events
%% ============================================================
%%
%% Pattern from DALI: weather_updateE stores state → internal events check
%% for risk conditions (temp > 38 or < 2, humidity < 20, storm).
%% Only risk conditions are forwarded to crop_advisor as weather_alert.

:- agent(weather_monitor, [cycle(1)]).

%% Receive weather update, store state for internal event validation
weather_monitor:on(weather_update(Temp, Humidity, Forecast)) :-
    log("Weather: T=~w H=~w F=~w", [Temp, Humidity, Forecast]),
    assert_belief(weather_state(Temp, Humidity, Forecast)),
    send(logger, log_event(weather_reading, weather_monitor, [Temp, Humidity, Forecast])).

%% Internal event: weather risk → send alert to crop_advisor
weather_monitor:internal(weather_risk_check, [forever]) :-
    believes(weather_state(Temp, Humidity, Forecast)),
    (Temp > 38 ; Temp < 2 ; Humidity < 20 ; Forecast = storm),
    log("WEATHER RISK: T=~w H=~w F=~w", [Temp, Humidity, Forecast]),
    retract_belief(weather_state(Temp, Humidity, Forecast)),
    send(crop_advisor, weather_alert(Temp, Humidity, Forecast)).

%% Internal event: normal weather — just clear state
weather_monitor:internal(weather_normal_check, [forever]) :-
    believes(weather_state(Temp, Humidity, Forecast)),
    Temp =< 38, Temp >= 2, Humidity >= 20, Forecast \= storm,
    log("WEATHER NORMAL: T=~w H=~w F=~w", [Temp, Humidity, Forecast]),
    retract_belief(weather_state(Temp, Humidity, Forecast)).

%% ============================================================
%% CROP ADVISOR — analyzes data with AI, decides actions
%% ============================================================
%%
%% Pattern from DALI: receives soil_report/weather_alert, optionally consults AI,
%% then decides action: irrigate, reduce_water, or advisory to farmer.

:- agent(crop_advisor, [cycle(1)]).

%% Handle soil report from sensor
crop_advisor:on(soil_report(Moisture, PH, Field)) :-
    log("Analyzing soil for ~w: M=~w pH=~w", [Field, Moisture, PH]),
    %% AI analysis if available
    ( ai_available ->
        ask_ai(soil_analysis(moisture(Moisture), ph(PH), field(Field)), Advice),
        log("AI recommends: ~w", [Advice])
    ; true ),
    %% Decide action based on conditions
    ( Moisture < 30 ->
        log("Low moisture → irrigate ~w", [Field]),
        send(irrigation_controller, irrigate(Field)),
        send(farmer_agent, advisory(irrigate, Field)),
        send(logger, log_event(action, crop_advisor, [irrigate, Field]))
    ; Moisture > 80 ->
        log("High moisture → reduce water ~w", [Field]),
        send(irrigation_controller, reduce_water(Field)),
        send(farmer_agent, advisory(reduce_water, Field)),
        send(logger, log_event(action, crop_advisor, [reduce_water, Field]))
    ; (PH < 5.5 ; PH > 7.5) ->
        log("Abnormal pH → advisory for ~w", [Field]),
        send(farmer_agent, advisory(ph_treatment, Field)),
        send(logger, log_event(action, crop_advisor, [ph_advisory, Field]))
    ;
        log("Conditions noted for ~w", [Field])
    ).

%% Handle weather alert from monitor
crop_advisor:on(weather_alert(Temp, Humidity, Forecast)) :-
    log("Weather alert: T=~w H=~w F=~w", [Temp, Humidity, Forecast]),
    %% AI analysis if available
    ( ai_available ->
        ask_ai(weather_analysis(temp(Temp), humidity(Humidity), forecast(Forecast)), Advice),
        log("AI recommends: ~w", [Advice])
    ; true ),
    %% Decide action based on conditions
    ( (Temp > 38 ; (Temp > 35, Humidity < 25)) ->
        log("Drought risk → emergency irrigation"),
        send(irrigation_controller, irrigate(all_fields)),
        send(farmer_agent, advisory(drought_risk, all_fields)),
        send(logger, log_event(action, crop_advisor, [drought_alert, all_fields]))
    ; Temp < 2 ->
        log("Frost warning → protect crops"),
        send(farmer_agent, advisory(frost_warning, all_fields)),
        send(logger, log_event(action, crop_advisor, [frost_warning, all_fields]))
    ; Forecast = storm ->
        log("Storm warning → prepare"),
        send(farmer_agent, advisory(storm_warning, all_fields)),
        send(logger, log_event(action, crop_advisor, [storm_warning, all_fields]))
    ;
        log("Weather conditions noted")
    ).

%% ============================================================
%% IRRIGATION CONTROLLER — activates irrigation or reduces water
%% ============================================================

:- agent(irrigation_controller, [cycle(1)]).

irrigation_controller:on(irrigate(Field)) :-
    log("Activating irrigation for ~w", [Field]),
    assert_belief(irrigation_state(active, Field)),
    send(farmer_agent, status(irrigating, Field)),
    send(logger, log_event(irrigation_started, irrigation_controller, [Field])).

irrigation_controller:on(reduce_water(Field)) :-
    log("Reducing water for ~w", [Field]),
    assert_belief(irrigation_state(reduced, Field)),
    send(farmer_agent, status(water_reduced, Field)),
    send(logger, log_event(irrigation_reduced, irrigation_controller, [Field])).

%% ============================================================
%% FARMER AGENT — receives advisories and status updates
%% ============================================================

:- agent(farmer_agent, [cycle(1)]).

farmer_agent:on(advisory(Action, Field)) :-
    log("ADVISORY: ~w for field ~w", [Action, Field]).

farmer_agent:on(status(State, Field)) :-
    log("STATUS UPDATE: ~w at field ~w", [State, Field]).

%% ============================================================
%% LOGGER — logs all events
%% ============================================================

:- agent(logger, [cycle(1)]).

logger:on(log_event(Type, Source, Data)) :-
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
