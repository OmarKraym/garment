-- Run in SQL Editor; every change, including demo data, rolls back.
BEGIN;
DO $$
DECLARE admin_id uuid; worker_id uuid; o uuid; l uuid; p uuid; t uuid; dst uuid; k uuid:=gen_random_uuid(); x jsonb; before_qty bigint; after_qty bigint; snap jsonb; blocked boolean; n int; result jsonb;
BEGIN
 SELECT auth_user_id INTO admin_id FROM factory.employees e WHERE EXISTS(SELECT 1 FROM factory.employee_roles r WHERE r.employee_id=e.id AND r.role='ADMIN' AND r.active) AND e.active LIMIT 1;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated')::text,true);
 PERFORM public.wip_dispatch('{"action":"seed"}',gen_random_uuid());
 IF (SELECT count(*) FROM wip.orders)<>2 THEN RAISE EXCEPTION 'Seed failed'; END IF;
 IF EXISTS(SELECT 1 FROM wip.orders o WHERE actual_cut_qty<>(SELECT sum(qty) FROM wip.lots WHERE order_id=o.id)) THEN RAISE EXCEPTION 'Conservation failed'; END IF;
 SELECT id INTO o FROM wip.orders WHERE order_no='DEMO-1';
 SELECT id,holder_id INTO l,t FROM wip.lots WHERE order_id=o AND station='tailor' AND state='active' AND qty=40 LIMIT 1;
 blocked:=false; BEGIN PERFORM public.wip_dispatch(jsonb_build_object('action','transfer','lotId',l,'qty',50,'to','finish1','type','forward'),gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM='الكمية تتجاوز الرصيد المتاح'; END; IF NOT blocked THEN RAISE EXCEPTION 'Overspend accepted'; END IF;
 SELECT id INTO p FROM wip.lots WHERE order_id=o AND station='tailor' AND state='pending' AND qty>0 LIMIT 1;
 blocked:=false; BEGIN PERFORM public.wip_dispatch(jsonb_build_object('action','transfer','lotId',p,'qty',1,'to','finish1','type','forward'),gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM='أكد الاستلام أولاً'; END; IF NOT blocked THEN RAISE EXCEPTION 'Pending moved'; END IF;
 blocked:=false; BEGIN PERFORM public.wip_dispatch(jsonb_build_object('action','transfer','lotId',l,'qty',1,'to','warehouse','type','forward'),gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM='هذا المسار غير مسموح'; END; IF NOT blocked THEN RAISE EXCEPTION 'Route bypass'; END IF;
 blocked:=false; BEGIN PERFORM public.wip_dispatch(jsonb_build_object('action','cut','orderId',o,'color','أبيض','size','M','qty',1),gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM='الكمية أقل من القطع الموجودة خارج القص'; END; IF NOT blocked THEN RAISE EXCEPTION 'Cut below distributed'; END IF;
 PERFORM public.wip_dispatch('{"action":"settings","allowReturns":false}',gen_random_uuid());
 blocked:=false; BEGIN PERFORM public.wip_dispatch(jsonb_build_object('action','transfer','lotId',l,'qty',1,'to','cutter','type','return','reason','عيب قص'),gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM='الإرجاع متوقف'; END; IF NOT blocked THEN RAISE EXCEPTION 'Returns toggle bypass'; END IF;
 PERFORM public.wip_dispatch('{"action":"settings","allowReturns":true}',gen_random_uuid());
 SELECT qty INTO before_qty FROM wip.lots WHERE id=l;
 x:=jsonb_build_object('action','transfer','lotId',l,'qty',1,'to','finish1','type','forward');
 PERFORM public.wip_dispatch(x,k); PERFORM public.wip_dispatch(x,k);
 SELECT qty INTO after_qty FROM wip.lots WHERE id=l;
 IF before_qty-after_qty<>1 THEN RAISE EXCEPTION 'Idempotency failed'; END IF;
 blocked:=false; BEGIN PERFORM public.wip_dispatch(x||'{"qty":2}',k); EXCEPTION WHEN OTHERS THEN blocked:=true; END; IF NOT blocked THEN RAISE EXCEPTION 'Reused key accepted changed payload'; END IF;
 SELECT id INTO dst FROM wip.tailors WHERE id<>t AND active LIMIT 1;
 SELECT id INTO l FROM wip.lots WHERE order_id=o AND station='finish1' AND state='active';
 PERFORM public.wip_dispatch(jsonb_build_object('action','transfer','lotId',l,'qty',2,'to','tailor','toHolder',dst,'type','rework','reason','عيب خياطة'),gen_random_uuid());
 SELECT id,qty INTO p,before_qty FROM wip.lots WHERE order_id=o AND station='tailor' AND holder_id=dst AND state='pending';
 PERFORM public.wip_dispatch(jsonb_build_object('action','confirm','lotId',p),gen_random_uuid());
 IF EXISTS(SELECT 1 FROM wip.lots WHERE id=p AND qty>0) THEN RAISE EXCEPTION 'Confirm failed'; END IF;
 -- Existing worker cannot access another person's tailor custody or settings.
 SELECT e.auth_user_id INTO worker_id FROM factory.employees e JOIN wip.tailors t ON t.employee_id=e.id WHERE e.active AND NOT e.must_change_password LIMIT 1;
 IF worker_id IS NULL THEN RAISE EXCEPTION 'No ready worker available for authorization test'; END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',worker_id,'role','authenticated')::text,true);
 blocked:=false; BEGIN PERFORM public.wip_dispatch('{"action":"settings","allowReturns":false}',gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=true; END; IF NOT blocked THEN RAISE EXCEPTION 'Worker changed settings'; END IF;
 SELECT l2.id INTO l FROM wip.lots l2 JOIN wip.tailors t2 ON t2.id=l2.holder_id LEFT JOIN factory.employees e2 ON e2.id=t2.employee_id WHERE l2.qty>0 AND l2.state='active' AND e2.auth_user_id IS DISTINCT FROM worker_id LIMIT 1;
 blocked:=false; BEGIN PERFORM public.wip_dispatch(jsonb_build_object('action','transfer','lotId',l,'qty',1,'to','finish1','type','forward'),gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=true; END; IF NOT blocked THEN RAISE EXCEPTION 'Wrong tailor accepted'; END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated')::text,true);
 snap:=public.wip_snapshot();
 IF EXISTS(SELECT 1 FROM wip.moves WHERE hash<>encode(extensions.digest(convert_to(prev_hash||payload_text,'UTF8'),'sha256'),'hex')) THEN RAISE EXCEPTION 'Hash mismatch'; END IF;
 PERFORM public.wip_dispatch(jsonb_build_object('action','restore','confirmation','استعادة النسخة','backup',snap),gen_random_uuid());
 IF (SELECT count(*) FROM wip.orders)<>2 THEN RAISE EXCEPTION 'Restore failed'; END IF;
 snap:=jsonb_set(snap,'{moves,0,qty}','999');
 blocked:=false; BEGIN PERFORM public.wip_dispatch(jsonb_build_object('action','restore','confirmation','استعادة النسخة','backup',snap),gen_random_uuid()); EXCEPTION WHEN OTHERS THEN blocked:=true; END; IF NOT blocked THEN RAISE EXCEPTION 'Tampered restore accepted'; END IF;
 IF has_function_privilege('anon','public.wip_dispatch(jsonb,uuid)','EXECUTE') OR has_table_privilege('authenticated','wip.lots','UPDATE') OR has_table_privilege('authenticated','wip.moves','INSERT') THEN RAISE EXCEPTION 'Direct privilege exposure'; END IF;
 -- Finish a fresh one-piece order to verify automatic closure.
 result:=public.wip_dispatch('{"action":"create","orderNo":"TEST-CLOSE","colors":["أبيض"],"sizes":["M"],"plannedQty":1}',gen_random_uuid());o:=(result->>'id')::uuid;
 PERFORM public.wip_dispatch(jsonb_build_object('action','cut','orderId',o,'color','أبيض','size','M','qty',1),gen_random_uuid());
 FOR x IN SELECT value FROM jsonb_array_elements('[{"from":"cutter","to":"tailor"},{"from":"tailor","to":"finish1"},{"from":"finish1","to":"press"},{"from":"press","to":"finish2"},{"from":"finish2","to":"warehouse"}]') LOOP
  SELECT id INTO l FROM wip.lots WHERE order_id=o AND station=x->>'from' AND state='active' AND qty=1;
  PERFORM public.wip_dispatch(jsonb_build_object('action','transfer','lotId',l,'qty',1,'to',x->>'to','type','forward','toHolder',CASE WHEN x->>'to'='tailor' THEN dst ELSE NULL END),gen_random_uuid());
  SELECT id INTO p FROM wip.lots WHERE order_id=o AND station=x->>'to' AND state='pending' AND qty=1;
  PERFORM public.wip_dispatch(jsonb_build_object('action','confirm','lotId',p),gen_random_uuid());
 END LOOP;
 IF (SELECT status FROM wip.orders WHERE id=o)<>'closed' THEN RAISE EXCEPTION 'Auto close failed'; END IF;
END $$;
SELECT 'PASS: conservation, overspend, pending, routing, cut lower bound, returns policy, idempotency, replay mismatch, rework confirmation, worker roles, holder authorization, hash, restore, tamper rejection, SQL grants, automatic close' AS result;
ROLLBACK;
