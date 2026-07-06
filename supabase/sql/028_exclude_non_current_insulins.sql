update public.medicines
set active = false,
    updated_at = now()
where external_code in (705, 706, 707);
