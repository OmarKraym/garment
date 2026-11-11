CREATE OR REPLACE FUNCTION wip.dispatch(p jsonb,k uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 a factory.actor_t:=factory.require_actor(true); act text:=p->>'action'; o wip.orders; l wip.lots; t wip.tailors;
 oid uuid; lid uuid; hid uuid; dest text; typ text; why text; q int; old int; outside_qty bigint; v_result jsonb; v_req wip.requests; v_allow boolean; v_prev text; v_entry jsonb; v_text text; v_check text; v_sum bigint; i int; j int; c text; z text; seed_ids uuid[]; seed_order uuid; seed_lot uuid;
BEGIN
 PERFORM factory.assert(k IS NOT NULL,'معرف العملية مطلوب');
 -- Serializes all small-factory writes, including confirmations, imports and audit hashes.
 SELECT allow_returns INTO v_allow FROM wip.settings WHERE id FOR UPDATE;
 SELECT * INTO v_req FROM wip.requests WHERE actor=a.employee_id AND key=k;
 IF FOUND THEN PERFORM factory.assert(v_req.payload=p,'معرف العملية مستخدم لطلب آخر'); RETURN v_req.result; END IF;
 IF act='create' THEN
  PERFORM factory.assert(wip.can_act(a,'supervisor'));
  PERFORM factory.assert(jsonb_typeof(p->'colors')='array' AND jsonb_array_length(p->'colors') BETWEEN 1 AND 20 AND jsonb_typeof(p->'sizes')='array' AND jsonb_array_length(p->'sizes') BETWEEN 1 AND 20,'اختر الألوان والمقاسات');
  FOR v_entry IN SELECT value FROM jsonb_array_elements((p->'colors')||(p->'sizes')) LOOP PERFORM factory.assert(jsonb_typeof(v_entry)='string' AND length(btrim(v_entry#>>'{}')) BETWEEN 1 AND 40,'لون أو مقاس غير صالح'); END LOOP;
  q:=factory.j_int(p,'plannedQty',1,1000000,'الكمية');
  INSERT INTO wip.orders(order_no,colors,sizes,planned_qty,note) VALUES(factory.j_text(p,'orderNo',1,60,true,'رقم الطلبية'),p->'colors',p->'sizes',q,coalesce(p->>'note','')) RETURNING id INTO oid;
 ELSIF act='cut' THEN
  PERFORM factory.assert(wip.can_act(a,'cutter'));
  oid:=(p->>'orderId')::uuid; SELECT * INTO o FROM wip.orders WHERE id=oid;
  PERFORM factory.assert(o.id IS NOT NULL,'الطلبية غير موجودة');
  c:=p->>'color'; z:=p->>'size'; PERFORM factory.assert(o.colors ? c AND o.sizes ? z,'لون أو مقاس خارج الطلبية');
  q:=factory.j_int(p,'qty',0,1000000,'الكمية المقصوصة');
  -- Actual cut is entered per color/size; the order total is derived from all lots.
  SELECT coalesce(sum(qty),0) INTO outside_qty FROM wip.lots WHERE order_id=oid AND color=c AND size=z AND station<>'cutter';
  PERFORM factory.assert(q>=outside_qty,'الكمية أقل من القطع الموجودة خارج القص');
  SELECT coalesce(sum(qty),0) INTO old FROM wip.lots WHERE order_id=oid AND color=c AND size=z;
  PERFORM factory.assert((SELECT coalesce(sum(qty),0) FROM wip.lots WHERE order_id=oid)-old+q<=1000000,'الحد الأقصى مليون قطعة');
  INSERT INTO wip.lots(order_id,color,size,qty,station,state) VALUES(oid,c,z,q-outside_qty,'cutter','active') ON CONFLICT(order_id,color,size,station,holder_id,state) DO UPDATE SET qty=excluded.qty,updated_at=now();
  UPDATE wip.orders SET actual_cut_qty=(SELECT coalesce(sum(qty),0) FROM wip.lots WHERE order_id=oid),status='cutting' WHERE id=oid;
  PERFORM wip.log(jsonb_build_object('type','cut_adjust','orderId',oid,'color',c,'size',z,'qty',q-old,'fromStation','cutter','toStation','cutter','fromHolder',NULL,'toHolder',NULL,'reason','تعديل كمية القص','actualQty',q));
 ELSIF act IN ('transfer','confirm') THEN
  lid:=(p->>'lotId')::uuid; SELECT * INTO l FROM wip.lots WHERE id=lid AND qty>0;
  PERFORM factory.assert(l.id IS NOT NULL,'الدفعة غير موجودة أو نفدت');
  PERFORM factory.assert(wip.can_act(a,l.station,l.holder_id)); oid:=l.order_id;
  IF act='confirm' THEN
   PERFORM factory.assert(l.state='pending','تم الاستلام مسبقاً');
   q:=l.qty; dest:=l.station;hid:=l.holder_id;typ:='confirm';why:=NULL;
  ELSE
   q:=factory.j_int(p,'qty',1,1000000,'الكمية');
   PERFORM factory.assert(l.state='active','أكد الاستلام أولاً');
   PERFORM factory.assert(q<=l.qty,'الكمية تتجاوز الرصيد المتاح');
   dest:=p->>'to'; hid:=nullif(p->>'toHolder','')::uuid;typ:=p->>'type'; why:=nullif(btrim(p->>'reason'),'');
   PERFORM factory.assert((typ='forward' AND (l.station,dest) IN (('cutter','tailor'),('tailor','finish1'),('finish1','press'),('press','finish2'),('finish2','warehouse'))) OR (typ IN ('return','rework') AND (l.station,dest) IN (('tailor','cutter'),('finish1','tailor'),('press','finish1'),('finish2','press'))),'هذا المسار غير مسموح');
   IF typ<>'forward' THEN PERFORM factory.assert(v_allow,'الإرجاع متوقف'); PERFORM factory.assert(why IS NOT NULL AND length(why)<=200,'اختر سبب الإرجاع'); END IF;
   IF dest='tailor' THEN PERFORM factory.assert(EXISTS(SELECT 1 FROM wip.tailors WHERE id=hid AND active),'اختر خياطاً فعالاً'); ELSE PERFORM factory.assert(hid IS NULL,'الخياط لا يخص هذه المرحلة'); END IF;
  END IF;
  UPDATE wip.lots SET qty=qty-q,updated_at=now() WHERE id=lid;
  INSERT INTO wip.lots(order_id,color,size,qty,station,holder_id,state) VALUES(oid,l.color,l.size,q,dest,hid,CASE WHEN act='confirm' OR dest='cutter' THEN 'active' ELSE 'pending' END) ON CONFLICT(order_id,color,size,station,holder_id,state) DO UPDATE SET qty=wip.lots.qty+excluded.qty,updated_at=now(),created_at=CASE WHEN wip.lots.qty=0 THEN now() ELSE wip.lots.created_at END;
  PERFORM wip.log(jsonb_build_object('type',typ,'orderId',oid,'color',l.color,'size',l.size,'qty',q,'fromStation',l.station,'fromHolder',l.holder_id,'toStation',dest,'toHolder',hid,'reason',why));
 ELSIF act='confirm_all' THEN
  dest:=p->>'station';hid:=nullif(p->>'holderId','')::uuid;
  PERFORM factory.assert(wip.can_act(a,dest,hid));
  FOR l IN SELECT * FROM wip.lots WHERE station=dest AND holder_id IS NOT DISTINCT FROM hid AND state='pending' AND qty>0 LOOP
   PERFORM wip.dispatch(jsonb_build_object('action','confirm','lotId',l.id),gen_random_uuid());
  END LOOP;
 ELSIF act='seed' THEN
  PERFORM factory.assert('ADMIN'=ANY(a.roles));
  PERFORM factory.assert(NOT EXISTS(SELECT 1 FROM wip.orders),'البيانات التجريبية متاحة عندما تكون قائمة الطلبيات فارغة فقط');
  SELECT array_agg(id ORDER BY name) INTO seed_ids FROM (SELECT id,name FROM wip.tailors WHERE active ORDER BY name LIMIT 6) t;
  PERFORM factory.assert(array_length(seed_ids,1)>=6,'تحتاج ستة خياطين فعالين');
  FOR j IN 1..2 LOOP
   v_result:=wip.dispatch(jsonb_build_object('action','create','orderNo','DEMO-'||j,'colors',CASE WHEN j=1 THEN '["أبيض","كحلي"]'::jsonb ELSE '["أسود"]'::jsonb END,'sizes',CASE WHEN j=1 THEN '["S","M","L","XL"]'::jsonb ELSE '["30","32","34"]'::jsonb END,'plannedQty',CASE WHEN j=1 THEN 400 ELSE 150 END,'note',CASE WHEN j=1 THEN 'قمصان بولو — تجريبي' ELSE 'بناطيل — تجريبي' END),gen_random_uuid());
   seed_order:=(v_result->>'id')::uuid;c:=CASE WHEN j=1 THEN 'أبيض' ELSE 'أسود' END;z:=CASE WHEN j=1 THEN 'M' ELSE '32' END;
   PERFORM wip.dispatch(jsonb_build_object('action','cut','orderId',seed_order,'color',c,'size',z,'qty',CASE WHEN j=1 THEN 396 ELSE 150 END),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='cutter';
   FOR i IN 1..6 LOOP
    PERFORM wip.dispatch(jsonb_build_object('action','transfer','lotId',seed_lot,'qty',CASE WHEN j=1 THEN 50 ELSE 15 END,'to','tailor','toHolder',seed_ids[i],'type','forward'),gen_random_uuid());
   END LOOP;
   FOR i IN 1..4 LOOP
    SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='tailor' AND holder_id=seed_ids[i] AND state='pending';
    PERFORM wip.dispatch(jsonb_build_object('action','confirm','lotId',seed_lot),gen_random_uuid());
   END LOOP;
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='tailor' AND holder_id=seed_ids[1] AND state='active';
   PERFORM wip.dispatch(jsonb_build_object('action','transfer','lotId',seed_lot,'qty',10,'to','finish1','type','forward'),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='finish1' AND state='pending';
   PERFORM wip.dispatch(jsonb_build_object('action','confirm','lotId',seed_lot),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='finish1' AND state='active';
   IF j=1 AND v_allow THEN PERFORM wip.dispatch(jsonb_build_object('action','transfer','lotId',seed_lot,'qty',2,'to','tailor','toHolder',seed_ids[2],'type','rework','reason','عيب خياطة'),gen_random_uuid()); END IF;
   PERFORM wip.dispatch(jsonb_build_object('action','transfer','lotId',seed_lot,'qty',5,'to','press','type','forward'),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='press' AND state='pending';
   PERFORM wip.dispatch(jsonb_build_object('action','confirm','lotId',seed_lot),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='press' AND state='active';
   PERFORM wip.dispatch(jsonb_build_object('action','transfer','lotId',seed_lot,'qty',3,'to','finish2','type','forward'),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='finish2' AND state='pending';
   PERFORM wip.dispatch(jsonb_build_object('action','confirm','lotId',seed_lot),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='finish2' AND state='active';
   PERFORM wip.dispatch(jsonb_build_object('action','transfer','lotId',seed_lot,'qty',3,'to','warehouse','type','forward'),gen_random_uuid());
   SELECT id INTO seed_lot FROM wip.lots WHERE order_id=seed_order AND station='warehouse' AND state='pending';
   PERFORM wip.dispatch(jsonb_build_object('action','confirm','lotId',seed_lot),gen_random_uuid());
  END LOOP;
 ELSIF act='settings' THEN
  PERFORM factory.assert('ADMIN'=ANY(a.roles));
  PERFORM factory.assert(jsonb_typeof(p->'allowReturns')='boolean','قيمة غير صالحة');
  UPDATE wip.settings SET allow_returns=(p->>'allowReturns')::boolean;
 ELSIF act='tailor' THEN
  PERFORM factory.assert('ADMIN'=ANY(a.roles));
  IF nullif(p->>'id','') IS NULL THEN
   INSERT INTO wip.tailors(name) VALUES(factory.j_text(p,'name',1,100,true,'الاسم')) RETURNING id INTO hid;
  ELSE
   hid:=(p->>'id')::uuid;
   PERFORM factory.assert(EXISTS(SELECT 1 FROM wip.tailors WHERE id=hid),'الخياط غير موجود');
   PERFORM factory.assert(jsonb_typeof(p->'active')='boolean','قيمة غير صالحة');
   IF NOT (p->>'active')::boolean THEN PERFORM factory.assert(NOT EXISTS(SELECT 1 FROM wip.lots WHERE holder_id=hid AND qty>0),'لا يمكن إيقاف خياط لديه عهدة'); END IF;
   IF p ? 'employeeId' THEN
    PERFORM factory.assert(NOT EXISTS(SELECT 1 FROM wip.lots WHERE holder_id=hid AND qty>0) OR (SELECT employee_id FROM wip.tailors WHERE id=hid) IS NOT DISTINCT FROM nullif(p->>'employeeId','')::uuid,'لا يمكن تغيير حساب خياط لديه عهدة');
    PERFORM factory.assert(nullif(p->>'employeeId','') IS NULL OR EXISTS(SELECT 1 FROM factory.employees e JOIN factory.employee_roles r ON r.employee_id=e.id JOIN factory.departments d ON d.id=r.department_id WHERE e.id=(p->>'employeeId')::uuid AND e.active AND r.active AND d.active AND d.stage='SEWING'),'اختر حساب خياط فعال');
    UPDATE wip.tailors SET employee_id=nullif(p->>'employeeId','')::uuid WHERE id=hid;
   END IF;
   UPDATE wip.tailors SET name=factory.j_text(p,'name',1,100,true,'الاسم'),active=(p->>'active')::boolean WHERE id=hid;
  END IF;
 ELSIF act='reset' THEN
  PERFORM factory.assert('ADMIN'=ANY(a.roles) AND p->>'confirmation'='مسح بيانات الإنتاج','تأكيد المسح مطلوب');
  DELETE FROM wip.lots; DELETE FROM wip.orders; DELETE FROM wip.moves;
  PERFORM factory.audit(a.employee_id,'wip.reset','wip',NULL,k::text,NULL);
 ELSIF act='restore' THEN
  PERFORM factory.assert('ADMIN'=ANY(a.roles),'الاستعادة للمدير فقط');
  PERFORM factory.assert(p->>'confirmation'='استعادة النسخة','تأكيد الاستعادة مطلوب');
  PERFORM factory.assert((p->'backup'->>'version')='1' AND jsonb_typeof(p->'backup'->'orders')='array' AND jsonb_typeof(p->'backup'->'lots')='array' AND jsonb_typeof(p->'backup'->'moves')='array' AND jsonb_typeof(p->'backup'->'tailors')='array','ملف غير صالح');
  DELETE FROM wip.lots; DELETE FROM wip.orders; DELETE FROM wip.moves; DELETE FROM wip.tailors;
  FOR v_entry IN SELECT value FROM jsonb_array_elements(p->'backup'->'tailors') LOOP
   INSERT INTO wip.tailors(id,name,active,employee_id) VALUES((v_entry->>'id')::uuid,v_entry->>'name',(v_entry->>'active')::boolean,(v_entry->>'employeeId')::uuid);
  END LOOP;
  FOR v_entry IN SELECT value FROM jsonb_array_elements(p->'backup'->'orders') LOOP
   INSERT INTO wip.orders(id,order_no,created_at,colors,sizes,planned_qty,actual_cut_qty,status,note) VALUES((v_entry->>'id')::uuid,v_entry->>'orderNo',(v_entry->>'createdAt')::timestamptz,v_entry->'colors',v_entry->'sizes',(v_entry->>'plannedQty')::int,(v_entry->>'actualCutQty')::int,v_entry->>'status',v_entry->>'note');
  END LOOP;
  FOR v_entry IN SELECT value FROM jsonb_array_elements(p->'backup'->'lots') LOOP
   INSERT INTO wip.lots(id,order_id,color,size,qty,station,holder_id,state,created_at,updated_at) VALUES((v_entry->>'id')::uuid,(v_entry->>'orderId')::uuid,v_entry->>'color',v_entry->>'size',(v_entry->>'qty')::int,v_entry->>'station',(v_entry->>'holderId')::uuid,v_entry->>'state',(v_entry->>'createdAt')::timestamptz,(v_entry->>'updatedAt')::timestamptz);
  END LOOP;
  v_prev:='';
  FOR v_entry IN SELECT value FROM jsonb_array_elements(p->'backup'->'moves') LOOP
   v_text:=v_entry->>'payloadText';
   PERFORM factory.assert(v_text::jsonb=v_entry-'payloadText'-'hash' AND v_entry->>'prevHash'=v_prev,'سلسلة الحركات غير سليمة');
   v_check:=encode(extensions.digest(convert_to(v_prev||v_text,'UTF8'),'sha256'),'hex');
   PERFORM factory.assert(v_check=v_entry->>'hash','سلسلة الحركات غير سليمة');
   INSERT INTO wip.moves(payload,payload_text,prev_hash,hash) VALUES(v_text::jsonb,v_text,v_prev,v_check); v_prev:=v_check;
  END LOOP;
  PERFORM factory.assert(NOT EXISTS(SELECT 1 FROM wip.lots l JOIN wip.orders o ON o.id=l.order_id WHERE NOT(o.colors ? l.color AND o.sizes ? l.size)),'ألوان أو مقاسات غير صالحة');
  PERFORM factory.assert(NOT EXISTS(SELECT 1 FROM wip.orders o WHERE coalesce(o.actual_cut_qty,0)<>(SELECT coalesce(sum(qty),0) FROM wip.lots WHERE order_id=o.id)),'مجموع العهد لا يطابق القص');
  UPDATE wip.settings SET allow_returns=(p->'backup'->'settings'->>'allowReturns')::boolean;
  PERFORM factory.audit(a.employee_id,'wip.restore','wip',NULL,k::text,NULL);
 ELSE RAISE EXCEPTION 'عملية غير معروفة';
 END IF;
 IF oid IS NOT NULL THEN
  UPDATE wip.orders SET status=CASE WHEN actual_cut_qty>0 AND actual_cut_qty=(SELECT coalesce(sum(qty),0) FROM wip.lots WHERE order_id=oid AND station='warehouse' AND state='active') AND NOT EXISTS(SELECT 1 FROM wip.lots WHERE order_id=oid AND qty>0 AND (station<>'warehouse' OR state<>'active')) THEN 'closed' WHEN EXISTS(SELECT 1 FROM wip.lots WHERE order_id=oid AND qty>0 AND station<>'cutter') THEN 'in_progress' WHEN actual_cut_qty IS NOT NULL THEN 'cutting' ELSE 'planned' END WHERE id=oid;
 END IF;
 UPDATE wip.settings SET revision=revision+1;
 v_result:=jsonb_build_object('ok',true,'id',coalesce(oid,hid),'revision',(SELECT revision FROM wip.settings));
 INSERT INTO wip.requests VALUES(a.employee_id,k,p,v_result);
 RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION wip.snapshot() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a factory.actor_t:=factory.require_actor(false); v jsonb;
BEGIN
 PERFORM factory.assert(NOT a.must_change,'يجب تغيير كلمة المرور من إدارة الحساب');
 SELECT jsonb_build_object('version',1,'revision',(SELECT revision FROM wip.settings),'me',to_jsonb(a),
 'staff',CASE WHEN 'ADMIN'=ANY(a.roles) THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'name',e.display_name)) FROM factory.employees e WHERE e.active AND EXISTS(SELECT 1 FROM factory.employee_roles r JOIN factory.departments d ON d.id=r.department_id WHERE r.employee_id=e.id AND r.active AND d.active AND d.stage='SEWING')),'[]'::jsonb) ELSE '[]'::jsonb END,
 'settings',jsonb_build_object('allowReturns',(SELECT allow_returns FROM wip.settings),'tailorCount',(SELECT count(*) FROM wip.tailors WHERE active)),
 'orders',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'orderNo',order_no,'createdAt',created_at,'colors',colors,'sizes',sizes,'plannedQty',planned_qty,'actualCutQty',actual_cut_qty,'status',status,'note',note) ORDER BY created_at DESC) FROM wip.orders),'[]'),
 'lots',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'orderId',order_id,'color',color,'size',size,'qty',qty,'station',station,'holderId',holder_id,'state',state,'createdAt',created_at,'updatedAt',updated_at)) FROM wip.lots WHERE qty>0),'[]'),
 'tailors',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active,'employeeId',employee_id) ORDER BY name) FROM wip.tailors),'[]'),
 'moves',coalesce((SELECT jsonb_agg(payload||jsonb_build_object('hash',hash,'payloadText',payload_text) ORDER BY seq) FROM wip.moves),'[]')) INTO v;
 RETURN v;
END $$;

