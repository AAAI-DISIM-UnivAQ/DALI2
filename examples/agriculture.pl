%% DALI2 Example: Smart Agriculture MAS
%% A multi-agent precision agriculture system.
%%
%% Agents:
%%   - soil_sensor:            receives soil readings, forwards to crop_advisor
%%   - weather_monitor:        receives weather data, forwards to crop_advisor
%%   - crop_advisor:           analyzes data, sends irrigation/advisory commands
%%   - irrigation_controller:  activates irrigation
%%   - farmer_agent:           receives notifications
%%   - logger:                 logs all events

%% ============================================================
%% SOIL SENSOR
%% ============================================================

:- agent(soil_sensor, [cycle(1)]).

soil_sensor:on(read_soil(Moisture, PH, Field)) :-
    log("Soil reading: moisture=~w, pH=~w, field=~w", [Moisture, PH, Field]),
    send(crop_advisor, soil_data(Moisture, PH, Field)),
    send(logger, log_event(soil_reading, soil_sensor, [Moisture, PH, Field])).

%% ============================================================
%% WEATHER MONITOR
%% ============================================================

:- agent(weather_monitor, [cycle(1)]).

weather_monitor:on(weather_update(Temp, Humidity, Forecast)) :-
    log("Weather: temp=~w, humidity=~w, forecast=~w", [Temp, Humidity, Forecast]),
    send(crop_advisor, weather_data(Temp, Humidity, Forecast)),
    send(logger, log_event(weather_reading, weather_monitor, [Temp, Humidity, Forecast])).

%% ============================================================
%% CROP ADVISOR
%% ============================================================

:- agent(crop_advisor, [cycle(1)]).

% Handle soil data
crop_advisor:on(soil_data(Moisture, PH, Field)) :-
    log("Analyzing soil for ~w: moisture=~w, pH=~w", [Field, Moisture, PH]),
    % Low moisture => irrigate
    ( Moisture < 30 ->
        log("Low moisture detected in ~w, requesting irrigation", [Field]),
        send(irrigation_controller, irrigate(Field, Moisture)),
        send(farmer_agent, notify(low_moisture, Field, Moisture))
    ; true ),
    % Abnormal pH => alert
    ( (PH < 5.5 ; PH > 7.5) ->
        log("Abnormal pH ~w in ~w", [PH, Field]),
        send(farmer_agent, notify(ph_alert, Field, PH))
    ; true ).

% Handle weather data
crop_advisor:on(weather_data(Temp, Humidity, Forecast)) :-
    log("Analyzing weather: temp=~w, humidity=~w, forecast=~w", [Temp, Humidity, Forecast]),
    % High temperature + low humidity => drought risk
    ( (Temp > 35, Humidity < 25) ->
        log("Drought risk detected!"),
        send(irrigation_controller, irrigate(all_fields, emergency)),
        send(farmer_agent, notify(drought_risk, Temp, Humidity))
    ; true ),
    % Frost warning
    ( Temp < 2 ->
        log("Frost warning! Temp=~w", [Temp]),
        send(farmer_agent, notify(frost_warning, Temp, Forecast))
    ; true ).

%% ============================================================
%% IRRIGATION CONTROLLER
%% ============================================================

:- agent(irrigation_controller, [cycle(1)]).

irrigation_controller:on(irrigate(Field, Reason)) :-
    log("Activating irrigation for ~w (reason: ~w)", [Field, Reason]),
    assert_belief(irrigating(Field)),
    send(farmer_agent, notify(irrigation_started, Field, Reason)),
    send(logger, log_event(irrigation, irrigation_controller, [Field, Reason])).

%% ============================================================
%% FARMER AGENT
%% ============================================================

:- agent(farmer_agent, [cycle(1)]).

farmer_agent:on(notify(Type, Arg1, Arg2)) :-
    log("Notification: ~w (~w, ~w)", [Type, Arg1, Arg2]),
    assert_belief(received_notification(Type, Arg1, Arg2)).

%% ============================================================
%% LOGGER
%% ============================================================

:- agent(logger, [cycle(1)]).

logger:on(log_event(Type, Source, Data)) :-
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
