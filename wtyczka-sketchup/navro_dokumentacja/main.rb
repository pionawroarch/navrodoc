require 'sketchup.rb'
require 'json'
require 'tmpdir'
require 'fileutils'

module Navro
  module Dokumentacja
    VERSION  = '0.3.0'
    FORMAT   = 'navro-dok'
    DIR      = File.dirname(__FILE__)
    ICONS    = File.join(DIR, 'icons')
    MAX_EDGES = 200_000   # limit krawędzi na scenę (przyciąganie)
    MAX_RAYS  = 90_000    # limit testów zasłonięcia na scenę
    WAIT      = 0.35      # s – czas na pełne przełączenie sceny (styl, warstwy, kamera)

    # ------------------------------------------------------------------
    # Okno wyboru scen
    # ------------------------------------------------------------------
    def self.show_dialog
      model = Sketchup.active_model
      if @busy
        UI.messagebox('Eksport już trwa – poczekaj na zakończenie.')
        return
      end
      if model.pages.count == 0
        UI.messagebox("Model nie ma żadnych scen.\nDodaj sceny (Widok › Animacja › Dodaj scenę) i spróbuj ponownie.")
        return
      end

      names = scene_ids(model).each_with_index.map { |id, i| { id: id, name: model.pages[i].name } }

      @dlg.close if @dlg
      @dlg = UI::HtmlDialog.new(
        dialog_title: 'navro. Dokumentacja – eksport scen',
        preferences_key: 'navro_dokumentacja_dlg2',
        width: 470, height: 680, min_width: 400, min_height: 480,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dlg.set_html(dialog_html)
      @dlg.add_action_callback('ready') do |_ctx|
        @dlg.execute_script("setScenes(#{names.to_json})")
      end
      @dlg.add_action_callback('export') do |_ctx, json|
        opts = JSON.parse(json)
        @dlg.close
        start_export(opts)
      end
      @dlg.add_action_callback('cancel') { |_ctx| @dlg.close }
      @dlg.show
    end

    # Unikalne identyfikatory scen (nazwa; duplikaty dostają sufiks)
    def self.scene_ids(model)
      seen = Hash.new(0)
      model.pages.map do |p|
        seen[p.name] += 1
        seen[p.name] > 1 ? "#{p.name} (#{seen[p.name]})" : p.name
      end
    end

    # ------------------------------------------------------------------
    # Eksport – sceny po kolei, z odczekaniem (SketchUp przełącza styl/warstwy
    # asynchronicznie, dlatego robienie wszystkiego w jednej pętli dawało jeden styl)
    # ------------------------------------------------------------------
    def self.start_export(opts)
      model = Sketchup.active_model
      ids   = scene_ids(model)
      wanted = opts['scenes'] || []

      base = (model.title.to_s.empty? ? 'model' : model.title.to_s)
      default_dir = model.path.to_s.empty? ? nil : File.dirname(model.path)
      target = UI.savepanel('Zapisz plik dla navro. Dokumentacja', default_dir, "#{base}.ndok")
      return unless target
      target += '.ndok' unless target.downcase.end_with?('.ndok')

      view = model.active_view
      cam  = view.camera
      popts = model.options['PageOptions']
      @job = {
        model: model, view: view, target: target, base: base,
        width: (opts['width'] || 4000).to_i, transparent: !!opts['transparent'],
        snap: opts['snap'] != false, occl: opts['occl'] != false,
        queue: model.pages.to_a.each_with_index.select { |_p, i| wanted.include?(ids[i]) }.map { |p, i| [p, i, ids[i]] },
        total: 0, scenes: [], tmp: Dir.mktmpdir('navro_dok'),
        orig_page: model.pages.selected_page,
        orig_style: model.styles.selected_style,
        orig_cam: Sketchup::Camera.new(cam.eye, cam.target, cam.up, cam.perspective?, cam.fov),
        orig_h: (cam.perspective? ? nil : cam.height),
        orig_trans: popts['TransitionTime'], orig_show: popts['ShowTransitions']
      }
      @job[:total] = @job[:queue].length
      @job[:done] = 0
      show_progress
      popts['ShowTransitions'] = false
      popts['TransitionTime'] = 0.0
      @busy = true
      next_scene
    end

    def self.next_scene
      job = @job
      if job[:cancel]
        abort_export
        return
      end
      if job[:queue].empty?
        finish_export
        return
      end
      page, idx, id = job[:queue].first
      n = job[:total] - job[:queue].length + 1
      Sketchup.status_text = "navro. Dokumentacja: scena #{n}/#{job[:total]} – #{page.name}"
      progress(job[:done], job[:total], "Scena #{n} z #{job[:total]}: #{page.name}", 'Przełączanie sceny (styl, warstwy, kamera)…')
      model = job[:model]
      begin
        model.pages.selected_page = page
        # jawnie styl sceny (inaczej SketchUp potrafi zostawić styl poprzedniej sceny)
        if page.respond_to?(:use_style?) && page.use_style? && page.style
          model.styles.selected_style = page.style
        end
        job[:view].invalidate
      rescue StandardError => e
        puts "navro. Dokumentacja: #{e.message}"
      end
      UI.start_timer(WAIT, false) { capture_scene(page, idx, id) }
    end

    def self.capture_scene(page, idx, id)
      job = @job
      view = job[:view]
      begin
        # drugi raz – na wypadek, gdyby przejście sceny nadpisało styl
        if page.respond_to?(:use_style?) && page.use_style? && page.style && job[:model].styles.selected_style != page.style
          job[:model].styles.selected_style = page.style
        end
        view.refresh
        c = view.camera
        vpw = [view.vpwidth, 1].max
        vph = [view.vpheight, 1].max
        img_w = job[:width]
        img_h = (img_w * vph.to_f / vpw).round
        n = job[:done] + 1
        progress(job[:done] + 0.2, job[:total], "Scena #{n} z #{job[:total]}: #{page.name}", 'Zapisywanie obrazu…')
        file = File.join(job[:tmp], "s#{idx}.png")
        ok = view.write_image(filename: file, width: img_w, height: img_h,
                              antialias: true, compression: 0.9, transparent: job[:transparent])
        if ok && File.exist?(file)
          data = File.binread(file)
          mm_per_px = c.perspective? ? nil : (c.height.to_f * 25.4) / img_h
          snap = nil
          if job[:snap]
            progress(job[:done] + 0.55, job[:total], "Scena #{n} z #{job[:total]}: #{page.name}", 'Zbieranie krawędzi do przyciągania…')
            begin
              snap = collect_snap(job[:model], view, img_w, img_h, job[:occl])
            rescue StandardError => e
              puts "navro. Dokumentacja (przyciąganie): #{e.message}"
            end
          end
          job[:scenes] << {
            id: id, name: page.name, index: idx, description: page.description.to_s,
            style: (page.style ? page.style.name : nil),
            pixelW: img_w, pixelH: img_h, perspective: c.perspective?, mmPerPx: mm_per_px,
            fov: (c.perspective? ? c.fov : nil),
            camera: {
              eye: c.eye.to_a.map { |v| (v.to_f * 25.4).round(2) },
              target: c.target.to_a.map { |v| (v.to_f * 25.4).round(2) },
              up: c.up.to_a.map { |v| v.to_f.round(6) },
              height_mm: (c.perspective? ? nil : (c.height.to_f * 25.4).round(3))
            },
            snap: snap,
            image: 'data:image/png;base64,' + [data].pack('m0')
          }
          File.delete(file) rescue nil
        end
      rescue StandardError => e
        puts "navro. Dokumentacja: #{e.message}"
      end
      job[:queue].shift
      job[:done] += 1
      progress(job[:done], job[:total], "Gotowe sceny: #{job[:done]} z #{job[:total]}", '')
      UI.start_timer(0.05, false) { next_scene }
    end

    def self.restore_state(job)
      model = job[:model]
      view = job[:view]
      popts = model.options['PageOptions']
      begin
        if job[:orig_page]
          model.pages.selected_page = job[:orig_page]
        else
          model.styles.selected_style = job[:orig_style] if job[:orig_style]
          view.camera = job[:orig_cam]
          view.camera.height = job[:orig_h] if job[:orig_h]
        end
      rescue StandardError
        nil
      end
      UI.start_timer(WAIT, false) do
        popts['TransitionTime'] = job[:orig_trans]
        popts['ShowTransitions'] = job[:orig_show]
      end
      view.invalidate
      FileUtils.remove_entry(job[:tmp]) rescue nil
      Sketchup.status_text = ''
      @busy = false
    end

    def self.abort_export
      job = @job
      close_progress
      restore_state(job)
      UI.messagebox("Eksport przerwany. Plik nie został zapisany.")
    end

    def self.finish_export
      job = @job
      progress(job[:total], job[:total], 'Zapisywanie pliku .ndok…', '')
      restore_state(job)

      doc = { format: FORMAT, version: 2, plugin: VERSION, model: job[:base],
              exported: Time.now.strftime('%Y-%m-%dT%H:%M:%S'), scenes: job[:scenes] }
      File.open(job[:target], 'wb') { |f| f.write(JSON.generate(doc)) }
      mb = (File.size(job[:target]) / 1048576.0).round(1)
      close_progress
      UI.messagebox("Wyeksportowano #{job[:scenes].length} scen (#{mb} MB):\n#{job[:target]}\n\nOtwórz ten plik w programie navro. Dokumentacja.\nPo zmianach w modelu wyeksportuj ponownie do tego samego pliku i użyj „Odśwież widoki”.")
    end

    # ------------------------------------------------------------------
    # Okno postępu (czarno-białe)
    # ------------------------------------------------------------------
    def self.show_progress
      close_progress
      ic = icon_data('n_48.png')
      @prog = UI::HtmlDialog.new(
        dialog_title: 'navro. Dokumentacja – eksport',
        preferences_key: 'navro_dokumentacja_prog',
        width: 420, height: 200, resizable: false,
        style: UI::HtmlDialog::STYLE_UTILITY
      )
      @prog.set_html(<<~HTML)
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        *{box-sizing:border-box}
        body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:#0b0b0b;color:#eee;font-size:13px;padding:16px 18px;user-select:none}
        .h{display:flex;gap:12px;align-items:center;margin-bottom:12px}
        .h img{width:30px;height:30px;border-radius:3px;border:1px solid #333}
        .t{font-weight:600;font-size:14px}
        #sc{color:#ddd;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .bar{height:10px;border-radius:5px;background:#262626;overflow:hidden;margin:10px 0 6px;border:1px solid #333}
        #fill{height:100%;width:0;background:#f2f2f2;transition:width .25s}
        .row{display:flex;justify-content:space-between;color:#9a9a9a;font-size:12px}
        button{margin-top:12px;float:right;background:#1a1a1a;color:#eee;border:1px solid #3a3a3a;border-radius:6px;padding:5px 14px;font:inherit}
        button:hover{background:#252525}
        </style></head><body>
        <div class="h"><img src="#{ic}"><div><div class="t">Eksport scen</div><div id="sc">Przygotowanie…</div></div></div>
        <div class="bar"><div id="fill"></div></div>
        <div class="row"><span id="st"></span><span id="pc">0%</span></div>
        <button onclick="sketchup.cancel()">Przerwij</button>
        <script>
        function upd(f,sc,st){document.getElementById('fill').style.width=(f*100).toFixed(1)+'%';document.getElementById('pc').textContent=Math.round(f*100)+'%';
          document.getElementById('sc').textContent=sc;document.getElementById('st').textContent=st;}
        </script></body></html>
      HTML
      @prog.add_action_callback('cancel') do |_ctx|
        @job[:cancel] = true if @job
        @prog.execute_script("upd(1,'Przerywanie…','Kończę bieżącą scenę')") rescue nil
      end
      @prog.set_on_closed { @job[:cancel] = true if @job && @busy } if @prog.respond_to?(:set_on_closed)
      @prog.show
    end

    def self.progress(done, total, scene, step)
      return unless @prog && @prog.visible?
      f = total > 0 ? [done.to_f / total, 1.0].min : 0
      @prog.execute_script("upd(#{f},#{scene.to_json},#{step.to_json})")
    rescue StandardError
      nil
    end

    def self.close_progress
      if @prog
        p = @prog
        @prog = nil
        p.set_on_closed {} if p.respond_to?(:set_on_closed)
        p.close rescue nil
      end
    end

    # ------------------------------------------------------------------
    # Geometria do przyciągania: widoczne krawędzie rzutowane na obraz,
    # punkty przecięcia krawędzi z aktywną płaszczyzną przekroju
    # ------------------------------------------------------------------
    def self.layer_visible?(layer)
      return true unless layer
      return false unless layer.visible?
      f = layer.respond_to?(:folder) ? layer.folder : nil
      while f
        return false if f.respond_to?(:visible?) && !f.visible?
        f = f.respond_to?(:folder) ? f.folder : nil
      end
      true
    end

    # płaszczyzna w układzie świata: [nx,ny,nz,d,znak_zachowanej_strony]
    def self.world_plane(sp, tr, dir)
      a, b, c, d = sp.get_plane
      n = Geom::Vector3d.new(a, b, c)
      return nil if n.length == 0
      p0 = Geom::Point3d.new(-a * d, -b * d, -c * d) # punkt na płaszczyźnie (n jednostkowy)
      p0 = p0.transform(tr)
      n = n.transform(tr)
      n.normalize!
      dd = -(n.x * p0.x + n.y * p0.y + n.z * p0.z)
      dot = n.dot(dir)
      sign = dot.abs > 0.05 ? (dot > 0 ? 1.0 : -1.0) : 1.0 # zachowana strona = w stronę patrzenia kamery
      [n.x, n.y, n.z, dd, sign]
    end

    def self.pval(pl, pt)
      (pl[0] * pt.x + pl[1] * pt.y + pl[2] * pt.z + pl[3]) * pl[4]
    end

    def self.collect_snap(model, view, img_w, img_h, occl)
      cam = view.camera
      eye = cam.eye
      dir = cam.direction
      persp = cam.perspective?
      sx = img_w.to_f / [view.vpwidth, 1].max
      sy = img_h.to_f / [view.vpheight, 1].max
      ro = model.rendering_options
      cuts_on = !(ro.respond_to?(:[]) && ro['DisplaySectionCuts'] == false)
      top_planes = []
      if cuts_on && model.entities.respond_to?(:active_section_plane) && model.entities.active_section_plane
        pl = world_plane(model.entities.active_section_plane, Geom::Transformation.new, dir)
        top_planes << pl if pl
      end

      segs = []
      verts = []
      secs = []
      seen = {}
      rays = 0
      edges = 0
      vis_cache = {}
      tol = 0.01

      visible = lambda do |pt|
        return true unless occl
        key = [(pt.x * 4).round, (pt.y * 4).round, (pt.z * 4).round]
        return vis_cache[key] if vis_cache.key?(key)
        if rays >= MAX_RAYS
          vis_cache[key] = true
          return true
        end
        dv = persp ? (eye - pt) : dir.reverse
        dist_eye = persp ? pt.distance(eye) : nil
        dv.normalize!
        origin = pt.offset(dv, 0.04)
        res = true
        6.times do
          rays += 1
          hit = model.raytest([origin, dv], true)
          break unless hit
          hp = hit[0]
          break if persp && pt.distance(hp) >= dist_eye
          if top_planes.all? { |pl| pval(pl, hp) >= -tol }
            res = false
            break
          end
          origin = hp.offset(dv, 0.04) # trafienie w część odciętą przekrojem – szukaj dalej
        end
        vis_cache[key] = res
        res
      end

      project = lambda do |pt|
        return nil if persp && (pt - eye).dot(dir) <= 0
        s = view.screen_coords(pt)
        x = s.x * sx
        y = s.y * sy
        return nil if x < -2 || y < -2 || x > img_w + 2 || y > img_h + 2
        [x.round(1), y.round(1)]
      end

      walk = nil
      walk = lambda do |ents, tr, planes|
        return if edges >= MAX_EDGES
        if cuts_on && !ents.equal?(model.entities) && ents.respond_to?(:active_section_plane) && ents.active_section_plane
          pl = world_plane(ents.active_section_plane, tr, dir)
          planes = planes + [pl] if pl
        end
        ents.each do |e|
          break if edges >= MAX_EDGES
          next if e.respond_to?(:hidden?) && e.hidden?
          next if e.respond_to?(:layer) && !layer_visible?(e.layer)
          if e.is_a?(Sketchup::Edge)
            next if e.soft?
            edges += 1
            p1 = e.start.position.transform(tr)
            p2 = e.end.position.transform(tr)
            skip = false
            planes.each do |pl|
              v1 = pval(pl, p1)
              v2 = pval(pl, p2)
              if v1 < -tol && v2 < -tol
                skip = true
                break
              end
              if (v1 < -tol && v2 > tol) || (v1 > tol && v2 < -tol)
                t = v1 / (v1 - v2)
                ip = Geom::Point3d.new(p1.x + (p2.x - p1.x) * t, p1.y + (p2.y - p1.y) * t, p1.z + (p2.z - p1.z) * t)
                if (q = project.call(ip))
                  k = "s#{q[0]},#{q[1]}"
                  unless seen[k]
                    seen[k] = true
                    secs.concat(q)
                  end
                end
                if v1 < 0 then p1 = ip else p2 = ip end
              end
            end
            next if skip
            a = project.call(p1)
            b = project.call(p2)
            next unless a && b
            if (a[0] - b[0]).abs < 0.6 && (a[1] - b[1]).abs < 0.6
              # krawędź widziana „na wprost” (np. pionowy narożnik ściany w rzucie) → punkt
              next unless visible.call(p1) || visible.call(p2)
              k = "v#{a[0].round},#{a[1].round}"
              next if seen[k]
              seen[k] = true
              verts.concat(a)
              next
            end
            mid = Geom::Point3d.new((p1.x + p2.x) / 2, (p1.y + p2.y) / 2, (p1.z + p2.z) / 2)
            next unless visible.call(mid) || visible.call(p1) || visible.call(p2)
            k = a[0] < b[0] || (a[0] == b[0] && a[1] < b[1]) ? "e#{a.join(',')},#{b.join(',')}" : "e#{b.join(',')},#{a.join(',')}"
            next if seen[k]
            seen[k] = true
            segs.concat(a).concat(b)
          elsif e.is_a?(Sketchup::Group)
            walk.call(e.entities, tr * e.transformation, planes)
          elsif e.is_a?(Sketchup::ComponentInstance)
            walk.call(e.definition.entities, tr * e.transformation, planes)
          end
        end
      end
      walk.call(model.entities, Geom::Transformation.new, top_planes)
      { s: segs, v: verts, p: secs, edges: edges, limited: edges >= MAX_EDGES }
    end

    # ------------------------------------------------------------------
    # HTML okna
    # ------------------------------------------------------------------
    def self.icon_data(name)
      path = File.join(ICONS, name)
      File.exist?(path) ? 'data:image/png;base64,' + [File.binread(path)].pack('m0') : ''
    end

    def self.dialog_html
      ic = icon_data('n_48.png')
      <<~HTML
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        *{box-sizing:border-box}
        body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:#0b0b0b;color:#e8e8e8;font-size:13px;display:flex;flex-direction:column;height:100vh;user-select:none}
        header{padding:14px 16px;border-bottom:1px solid #262626;display:flex;gap:12px;align-items:center}
        header img{width:38px;height:38px;border-radius:4px;border:1px solid #2a2a2a}
        .logo{font-family:Poppins,'Segoe UI',sans-serif;font-weight:600;font-size:17px}
        .sub{color:#8a8a8a;margin-top:1px;font-size:12px}
        #list{flex:1;overflow:auto;padding:6px 12px}
        label.row{display:flex;gap:10px;align-items:center;padding:7px 8px;border-radius:6px;cursor:default}
        label.row:hover{background:#1a1a1a}
        .bar{display:flex;gap:8px;padding:10px 16px 4px;align-items:center}
        .bar span{margin-left:auto;color:#8a8a8a;font-size:12px}
        button{background:#1a1a1a;color:#e8e8e8;border:1px solid #2a2a2a;border-radius:6px;padding:6px 12px;cursor:default;font:inherit}
        button:hover{border-color:#3a3a3a;background:#222}
        button.pri{background:#f2f2f2;color:#111;border-color:#f2f2f2;font-weight:600}
        button.pri:hover{background:#fff}
        footer{border-top:1px solid #262626;padding:12px 16px;display:flex;flex-direction:column;gap:10px}
        select{background:#1a1a1a;color:#e8e8e8;border:1px solid #2a2a2a;border-radius:6px;padding:4px 6px;font:inherit}
        .f{display:flex;align-items:center;gap:8px}
        .hint{color:#8a8a8a;font-size:12px;line-height:1.45}
        input[type=checkbox]{accent-color:#f2f2f2;width:15px;height:15px}
        </style></head><body>
        <header><img src="#{ic}"><div><div class="logo">navro. Dokumentacja</div><div class="sub">Eksport scen do programu dokumentacji</div></div></header>
        <div class="bar"><button onclick="all(true)">Zaznacz wszystkie</button><button onclick="all(false)">Odznacz</button><span id="cnt">0 zaznaczonych</span></div>
        <div id="list"></div>
        <footer>
          <div class="f">Rozdzielczość (szerokość):
            <select id="w"><option>2500</option><option>3500</option><option selected>4000</option><option>6000</option><option>8000</option></select> px</div>
          <label class="f"><input type="checkbox" id="tr"> Przezroczyste tło</label>
          <label class="f"><input type="checkbox" id="sn" checked> Punkty przyciągania (krawędzie modelu)</label>
          <label class="f"><input type="checkbox" id="oc" checked> Pomijaj krawędzie zasłonięte</label>
          <div class="hint">Każda scena jest eksportowana z własnym stylem, warstwami i kamerą. Skala jest liczona dla scen w rzucie równoległym.</div>
          <div class="f" style="justify-content:flex-end"><button onclick="sketchup.cancel()">Anuluj</button><button class="pri" onclick="go()">Eksportuj…</button></div>
        </footer>
        <script>
        function upd(){var n=document.querySelectorAll('#list input:checked').length;document.getElementById('cnt').textContent=n+' zaznaczonych';}
        function setScenes(a){var h='';a.forEach(function(s,i){h+='<label class="row"><input type="checkbox" onchange="upd()" data-id="'+encodeURIComponent(s.id)+'"> '+(i+1)+'. '+s.name.replace(/</g,'&lt;')+'</label>';});document.getElementById('list').innerHTML=h;upd();}
        function all(v){document.querySelectorAll('#list input').forEach(function(c){c.checked=v;});upd();}
        function go(){var ids=[];document.querySelectorAll('#list input').forEach(function(c){if(c.checked)ids.push(decodeURIComponent(c.dataset.id));});
          if(!ids.length){alert('Zaznacz co najmniej jedną scenę.');return;}
          sketchup.export(JSON.stringify({scenes:ids,width:+document.getElementById('w').value,transparent:document.getElementById('tr').checked,
            snap:document.getElementById('sn').checked,occl:document.getElementById('oc').checked}));}
        window.onload=function(){sketchup.ready();};
        </script></body></html>
      HTML
    end

    # ------------------------------------------------------------------
    unless file_loaded?(__FILE__)
      cmd = UI::Command.new('navro. Dokumentacja') { show_dialog }
      cmd.tooltip = 'navro. Dokumentacja – eksport scen'
      cmd.status_bar_text = 'Eksportuj sceny do programu navro. Dokumentacja'
      cmd.small_icon = File.join(ICONS, 'n_32.png')
      cmd.large_icon = File.join(ICONS, 'n_48.png')
      menu = UI.menu('Extensions').add_submenu('navro. Dokumentacja')
      menu.add_item(cmd)
      tb = UI::Toolbar.new('navro. Dokumentacja')
      tb.add_item(cmd)
      tb.get_last_state == TB_NEVER_SHOWN ? tb.show : tb.restore
      file_loaded(__FILE__)
    end
  end
end
