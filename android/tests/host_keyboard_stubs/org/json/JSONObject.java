package org.json;
import java.util.HashMap;
public class JSONObject {
    private final HashMap<String,Object> values=new HashMap<>();
    public JSONObject() {}
    public JSONObject(String raw) { values.put("version",1); values.put("type","software-keyboard"); values.put("mode",0); values.put("min",0); values.put("max",16); for (String key : new String[]{"guide","initial","header","subtitle","submit"}) values.put(key,""); }
    public int getInt(String k) throws JSONException { Object v=values.get(k); if (!(v instanceof Integer)) throw new JSONException(k); return (Integer)v; }
    public String getString(String k) throws JSONException { Object v=values.get(k); if (!(v instanceof String)) throw new JSONException(k); return (String)v; }
    public JSONObject put(String k, Object v) throws JSONException { values.put(k,v); return this; }
    public String toString() { return String.valueOf(values.get("status")); }
}
