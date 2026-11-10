begin;
create or replace function mama_briefing.business_day(p_date date, p_days int) returns date
language plpgsql immutable strict set search_path = '' as $$
declare
  y int;
  golden int;
  century int;
  correction int;
  leap_adjust int;
  offset_day int;
  easter_index int;
  good_friday date;
begin
  while p_days <> 0 loop
    p_date := p_date + sign(p_days)::int;
    if extract(isodow from p_date) >= 6 or extract(month from p_date)::int * 100 + extract(day from p_date)::int
      in (101,421,501,907,1012,1102,1115,1120,1225) then continue; end if;
    if extract(month from p_date) in (3,4) then
      -- Gregorian Easter, using the Meeus/Jones/Butcher calculation.
      y := extract(year from p_date)::int;
      golden := y % 19;
      century := y / 100;
      correction := (19 * golden + century - century / 4 - (century - (century + 8) / 25 + 1) / 3 + 15) % 30;
      leap_adjust := (32 + 2 * (century % 4) + 2 * ((y % 100) / 4) - correction - y % 4) % 7;
      offset_day := (golden + 11 * correction + 22 * leap_adjust) / 451;
      easter_index := correction + leap_adjust - 7 * offset_day + 114;
      good_friday := make_date(y,easter_index / 31,easter_index % 31 + 1) - 2;
      if p_date = good_friday then continue; end if;
    end if;
    p_days := p_days - sign(p_days)::int;
  end loop;
  return p_date;
end $$;
commit;
