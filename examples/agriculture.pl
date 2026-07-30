%% DALI2 Example: Smart Agriculture MAS
%% Ported from the original DALI agriculture case study (dalia/case_study_smart_agriculture).
%%
%% Agents (6):
%%   - soil_sensor:            receives soil readings, validates and forwards abnormal
%%   - weather_monitor:        receives weather data, validates and forwards risks
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
%% SOIL SENSOR — receives readings, validates and forwards
%% ============================================================

:- agent(soil_sensor, [cycle(1)]).

%% Receive soil reading, validate and forward if abnormal
read_soilE(Moisture, PH, Field) :>
    log("Soil reading: M=~w pH=~w Field=~w", [Moisture, PH, Field]),
    messageA(logger, send_message(log_event(soil_reading, soil_sensor, [Moisture, PH, Field]), Me)),
    ( (Moisture < 30 ; Moisture > 80 ; PH < 5.5 ; PH > 7.5) ->
        log("SOIL ALERT: M=~w pH=~w Field=~w", [Moisture, PH, Field]),
        messageA(crop_advisor, send_message(soil_report(Moisture, PH, Field), Me))
    ;
        log("SOIL NORMAL: M=~w pH=~w Field=~w", [Moisture, PH, Field])
    ).

%% ============================================================
%% WEATHER MONITOR — receives weather data, validates and forwards
%% ============================================================

:- agent(weather_monitor, [cycle(1)]).

%% Receive weather update, validate and forward if risk
weather_updateE(Temp, Humidity, Forecast) :>
    log("Weather: T=~w H=~w F=~w", [Temp, Humidity, Forecast]),
    messageA(logger, send_message(log_event(weather_reading, weather_monitor, [Temp, Humidity, Forecast]), Me)),
    ( (Temp > 38 ; Temp < 2 ; Humidity < 20 ; Forecast = storm) ->
        log("WEATHER RISK: T=~w H=~w F=~w", [Temp, Humidity, Forecast]),
        messageA(crop_advisor, send_message(weather_alert(Temp, Humidity, Forecast), Me))
    ;
        log("WEATHER NORMAL: T=~w H=~w F=~w", [Temp, Humidity, Forecast])
    ).

%% ============================================================
%% CROP ADVISOR — analyzes data with AI, decides actions
%% ============================================================

:- agent(crop_advisor, [cycle(1)]).

%% Handle soil report from sensor
soil_reportE(Moisture, PH, Field) :>
    log("Analyzing soil for ~w: M=~w pH=~w", [Field, Moisture, PH]),
    %% AI analysis if available
    ( ai_available ->
        ask_ai(soil_analysis(moisture(Moisture), ph(PH), field(Field)), Advice),
        log("AI recommends: ~w", [Advice])
    ; true ),
    %% Decide action based on conditions
    ( Moisture < 30 ->
        log("Low moisture -> irrigate ~w", [Field]),
        messageA(irrigation_controller, send_message(irrigate(Field), Me)),
        messageA(farmer_agent, send_message(advisory(irrigate, Field), Me)),
        messageA(logger, send_message(log_event(action, crop_advisor, [irrigate, Field]), Me))
    ; Moisture > 80 ->
        log("High moisture -> reduce water ~w", [Field]),
        messageA(irrigation_controller, send_message(reduce_water(Field), Me)),
        messageA(farmer_agent, send_message(advisory(reduce_water, Field), Me)),
        messageA(logger, send_message(log_event(action, crop_advisor, [reduce_water, Field]), Me))
    ; (PH < 5.5 ; PH > 7.5) ->
        log("Abnormal pH -> advisory for ~w", [Field]),
        messageA(farmer_agent, send_message(advisory(ph_treatment, Field), Me)),
        messageA(logger, send_message(log_event(action, crop_advisor, [ph_advisory, Field]), Me))
    ;
        log("Conditions noted for ~w", [Field])
    ).

%% Handle weather alert from monitor
weather_alertE(Temp, Humidity, Forecast) :>
    log("Weather alert: T=~w H=~w F=~w", [Temp, Humidity, Forecast]),
    %% AI analysis if available
    ( ai_available ->
        ask_ai(weather_analysis(temp(Temp), humidity(Humidity), forecast(Forecast)), Advice),
        log("AI recommends: ~w", [Advice])
    ; true ),
    %% Decide action based on conditions
    ( (Temp > 38 ; (Temp > 35, Humidity < 25)) ->
        log("Drought risk -> emergency irrigation"),
        messageA(irrigation_controller, send_message(irrigate(all_fields), Me)),
        messageA(farmer_agent, send_message(advisory(drought_risk, all_fields), Me)),
        messageA(logger, send_message(log_event(action, crop_advisor, [drought_alert, all_fields]), Me))
    ; Temp < 2 ->
        log("Frost warning -> protect crops"),
        messageA(farmer_agent, send_message(advisory(frost_warning, all_fields), Me)),
        messageA(logger, send_message(log_event(action, crop_advisor, [frost_warning, all_fields]), Me))
    ; Forecast = storm ->
        log("Storm warning -> prepare"),
        messageA(farmer_agent, send_message(advisory(storm_warning, all_fields), Me)),
        messageA(logger, send_message(log_event(action, crop_advisor, [storm_warning, all_fields]), Me))
    ;
        log("Weather conditions noted")
    ).

%% ============================================================
%% IRRIGATION CONTROLLER — activates irrigation or reduces water
%% ============================================================

:- agent(irrigation_controller, [cycle(1)]).

irrigateE(Field) :>
    log("Activating irrigation for ~w", [Field]),
    assert_belief(irrigation_state(active, Field)),
    messageA(farmer_agent, send_message(status(irrigating, Field), Me)),
    messageA(logger, send_message(log_event(irrigation_started, irrigation_controller, [Field]), Me)).

reduce_waterE(Field) :>
    log("Reducing water for ~w", [Field]),
    assert_belief(irrigation_state(reduced, Field)),
    messageA(farmer_agent, send_message(status(water_reduced, Field), Me)),
    messageA(logger, send_message(log_event(irrigation_reduced, irrigation_controller, [Field]), Me)).

%% ============================================================
%% FARMER AGENT — receives advisories and status updates
%% ============================================================

:- agent(farmer_agent, [cycle(1)]).

advisoryE(Action, Field) :>
    log("ADVISORY: ~w for field ~w", [Action, Field]).

statusE(State, Field) :>
    log("STATUS UPDATE: ~w at field ~w", [State, Field]).

%% ============================================================
%% LOGGER — logs all events
%% ============================================================

:- agent(logger, [cycle(1)]).

log_eventE(Type, Source, Data) :>
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
