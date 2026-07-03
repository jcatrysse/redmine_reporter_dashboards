# frozen_string_literal: true

module RedmineReporterDashboards
  # JavaScript shims injected into report PDFs.
  #
  # wkhtmltopdf renders with a very old QtWebKit (AppleWebKit 534.x, ~2011) that
  # lacks a number of ES5.1/ES2015 features — notably Function.prototype.bind,
  # window.requestAnimationFrame, Object.assign and several Array/Number/String
  # methods. Chart.js 2.8 (and most modern chart libraries) call these and throw
  # "'undefined' is not a function" during rendering, leaving an empty <canvas>
  # in the PDF while the plain HTML/CSS around it renders fine.
  #
  # Injecting these polyfills before the report's own scripts run makes the
  # charts render in the PDF. They are all guarded (`if (!x) x = ...`), so on a
  # capable engine (a real browser) they are no-ops.
  module PdfPolyfills
    SCRIPT = <<~'HTML'
      <script>
      /* redmine_reporter_dashboards: ES2015 shims for wkhtmltopdf's old WebKit */
      if(!Function.prototype.bind){Function.prototype.bind=function(o){var a=Array.prototype.slice.call(arguments,1),f=this,N=function(){},B=function(){return f.apply(this instanceof N?this:o,a.concat(Array.prototype.slice.call(arguments)));};if(this.prototype)N.prototype=this.prototype;B.prototype=new N();return B;};}
      if(!window.requestAnimationFrame){window.requestAnimationFrame=function(cb){return setTimeout(function(){cb(Date.now());},16);};window.cancelAnimationFrame=function(i){clearTimeout(i);};}
      if(!Object.assign){Object.assign=function(t){for(var i=1;i<arguments.length;i++){var s=arguments[i];if(s)for(var k in s)if(Object.prototype.hasOwnProperty.call(s,k))t[k]=s[k];}return t;};}
      if(!Array.prototype.find){Array.prototype.find=function(f){for(var i=0;i<this.length;i++)if(f(this[i],i,this))return this[i];};}
      if(!Array.prototype.findIndex){Array.prototype.findIndex=function(f){for(var i=0;i<this.length;i++)if(f(this[i],i,this))return i;return -1;};}
      if(!Array.prototype.fill){Array.prototype.fill=function(v){var O=Object(this),len=O.length>>>0,s=arguments[1]>>0,k=s<0?Math.max(len+s,0):Math.min(s,len),e=arguments[2]===undefined?len:arguments[2]>>0,f=e<0?Math.max(len+e,0):Math.min(e,len);while(k<f){O[k]=v;k++;}return O;};}
      if(!Array.prototype.includes){Array.prototype.includes=function(s){return this.indexOf(s)!==-1;};}
      if(!Array.from){Array.from=function(a){var r=[];for(var i=0;i<a.length;i++)r.push(a[i]);return r;};}
      if(!Number.isNaN){Number.isNaN=function(v){return v!==v;};}
      if(!Number.isFinite){Number.isFinite=function(v){return typeof v==='number'&&isFinite(v);};}
      if(!Number.isInteger){Number.isInteger=function(v){return typeof v==='number'&&isFinite(v)&&Math.floor(v)===v;};}
      if(!Math.sign){Math.sign=function(x){x=+x;return x>0?1:x<0?-1:x;};}
      if(!Math.log10){Math.log10=function(x){return Math.log(x)/Math.LN10;};}
      if(!String.prototype.startsWith){String.prototype.startsWith=function(s){return this.indexOf(s)===0;};}
      if(!String.prototype.includes){String.prototype.includes=function(s){return this.indexOf(s)!==-1;};}
      if(!String.prototype.repeat){String.prototype.repeat=function(n){return new Array(n+1).join(this);};}
      </script>
    HTML

    module_function

    # Does this report render a JavaScript chart? A <canvas> element is the
    # reliable signal (Chart.js and friends draw into one). Used to apply the
    # polyfills and the wait-for-charts delay ONLY when a report actually needs
    # them, so plain (table) reports keep exporting at full speed.
    def charts?(html)
      html.is_a?(String) && html.match?(/<canvas[\s>\/]/i)
    end

    # Insert the shims right after <body> (so they run before the report's own
    # scripts), falling back to prepending when there is no <body> tag.
    def inject(html)
      return html if html.nil?

      if html =~ /<body[^>]*>/i
        html.sub(/<body[^>]*>/i) { |tag| "#{tag}\n#{SCRIPT}" }
      else
        "#{SCRIPT}#{html}"
      end
    end
  end
end
